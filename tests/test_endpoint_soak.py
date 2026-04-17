# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "azure-ai-ml>=1.15.0",
#     "azure-identity>=1.15.0",
#     "requests>=2.31.0",
# ]
# ///
"""
Soak / Prolonged Endpoint Test — Azure AI Foundry Managed Compute Endpoints.

Runs a continuous or bounded loop of endpoint calls, rotating through
authentication methods (Key / AAD / AML) in round-robin order.  Produces
incremental JSONL results and a single final HTML summary report.

Key features:
    - Round-robin auth rotation across Key / AAD / AML (configurable subset).
    - Auto-switches endpoint authMode per iteration (reuses quick-script logic).
    - Writes one JSON record per iteration to results.jsonl (no per-test report).
    - Generates a single offline HTML report with summary cards, SVG charts,
      auth/model breakdowns, and a colour-coded detail table.
    - Graceful Ctrl+C handling: restores original authMode and writes report.
    - Never prints secrets (keys/tokens) to console or HTML.

Usage:
    uv run tests/test_endpoint_soak.py --duration-seconds 3600 --max-tests 100
    uv run tests/test_endpoint_soak.py --auth key,aad --max-tests 50
    uv run tests/test_endpoint_soak.py                   # runs until Ctrl+C

Prerequisites:
    uv tool install (https://docs.astral.sh/uv/)
    az login
"""

import argparse
import contextlib
import html as html_mod
import io
import json
import math
import random
import signal
import sys
import time
from datetime import datetime, timedelta, timezone
from itertools import cycle
from pathlib import Path

# ---------------------------------------------------------------------------
# Ensure sibling module is importable regardless of working directory.
# ---------------------------------------------------------------------------
sys.path.insert(0, str(Path(__file__).resolve().parent))

try:
    from test_endpoint_quick import (
        AUTH_MODE_MAP,
        DEFAULT_INPUTS,
        build_payload,
        detect_payload_format,
        extract_endpoint_name,
        extract_model_name,
        fetch_aad_token,
        fetch_aml_token,
        fetch_endpoint_key,
        get_current_auth_mode,
        get_source_ip,
        has_workspace_details,
        invoke_endpoint,
        preflight_check,
        prompt_config,
        switch_auth_mode,
    )
except ImportError:
    print("ERROR: Cannot import from test_endpoint_quick.py.")
    print("Ensure test_endpoint_quick.py is in the same directory as this script.")
    sys.exit(1)

try:
    import requests
    from azure.ai.ml import MLClient
    from azure.identity import DefaultAzureCredential
except ImportError as exc:
    print(f"Missing dependency: {exc.name}")
    print("Run with:  uv run tests/test_endpoint_soak.py  (auto-installs deps)")
    sys.exit(1)


# ===========================================================================
# Constants
# ===========================================================================
AUTH_SWITCH_WAIT_SECONDS = 10


# ===========================================================================
# CLI
# ===========================================================================

def parse_args() -> argparse.Namespace:
    """Parse command-line arguments for the soak test."""
    p = argparse.ArgumentParser(
        description="Soak / prolonged test for Azure AI Foundry managed endpoints.",
    )
    p.add_argument(
        "--duration-seconds", type=int, default=None,
        help="Total run time in seconds (omit for unlimited).",
    )
    p.add_argument(
        "--max-tests", type=int, default=None,
        help="Maximum number of iterations (omit for unlimited).",
    )
    p.add_argument(
        "--models", type=str, default=None,
        help="Comma-separated model labels to round-robin for result tracking.",
    )
    p.add_argument(
        "--auth", type=str, default="key,aad,aml",
        help="Comma-separated auth methods to rotate: key,aad,aml (default: key,aad,aml).",
    )
    p.add_argument(
        "--output-dir", type=str, default=None,
        help="Output directory for results.jsonl + report.html "
             "(default: soak_results/<timestamp>/).",
    )
    p.add_argument(
        "--bucket-seconds", type=int, default=60,
        help="Histogram time-bucket width in seconds (default: 60).",
    )
    return p.parse_args()


# ===========================================================================
# Helpers
# ===========================================================================

@contextlib.contextmanager
def quiet_stdout():
    """Suppress stdout temporarily to keep soak-test console output concise."""
    old = sys.stdout
    sys.stdout = io.StringIO()
    try:
        yield
    finally:
        sys.stdout = old


def percentile(values: list[float], pct: float) -> float:
    """Compute a percentile via linear interpolation."""
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * (pct / 100.0)
    f, c = int(math.floor(k)), int(math.ceil(k))
    if f == c:
        return s[f]
    return s[f] * (c - k) + s[c] * (k - f)


def group_stats(records: list[dict]) -> dict:
    """Compute summary statistics for a list of result records."""
    total = len(records)
    passes = sum(1 for r in records if r["success"])
    fails = total - passes
    times = [r["response_ms"] for r in records if r["success"]]
    return {
        "total": total,
        "passes": passes,
        "fails": fails,
        "pass_rate": round(passes / total * 100, 1) if total else 0.0,
        "avg_ms": round(sum(times) / len(times), 1) if times else 0.0,
        "p50_ms": round(percentile(times, 50), 1),
        "p95_ms": round(percentile(times, 95), 1),
    }


# ===========================================================================
# Credential dispatcher
# ===========================================================================

def fetch_credential(method: str, ml_client: MLClient, endpoint_name: str) -> str:
    """Fetch the appropriate credential for *method* (key / aad / aml)."""
    if method == "key":
        return fetch_endpoint_key(ml_client, endpoint_name)
    elif method == "aad":
        return fetch_aad_token()
    elif method == "aml":
        return fetch_aml_token(ml_client, endpoint_name)
    raise ValueError(f"Unknown auth method: {method}")


# ===========================================================================
# Single iteration
# ===========================================================================

def pick_random_inputs(fmt: str) -> tuple[list[str], dict]:
    """Randomly pick 1–3 samples from DEFAULT_INPUTS and build the payload."""
    k = random.randint(1, len(DEFAULT_INPUTS))
    chosen = random.sample(DEFAULT_INPUTS, k)
    return chosen, build_payload(chosen, fmt)


def do_iteration(
    index: int,
    auth_method: str,
    model_label: str | None,
    config: dict,
    ml_client: MLClient,
    current_endpoint_auth: str,
) -> dict:
    """Execute one endpoint call, returning a structured result record."""
    ts = datetime.now(timezone.utc).isoformat()
    rec: dict = {
        "timestamp": ts,
        "iteration": index,
        "endpoint_name": config["endpoint_name"],
        "payload_format": config["payload_format"],
        "auth_method": auth_method.upper(),
        "model_label": model_label,
        "response_model": None,
        "success": False,
        "http_status": None,
        "response_ms": 0.0,
        "request_id": None,
        "ms_request_id": None,
        "error_category": None,
        "error_message": None,
        "auth_switched": False,
    }

    target = AUTH_MODE_MAP[auth_method]

    # ------------------------------------------------------------------
    # 1. Switch authMode on the endpoint if needed
    # ------------------------------------------------------------------
    try:
        if current_endpoint_auth.lower() != target.lower():
            with quiet_stdout():
                switch_auth_mode(ml_client, config["endpoint_name"], target)
            rec["auth_switched"] = True
            time.sleep(AUTH_SWITCH_WAIT_SECONDS)
    except Exception as exc:
        rec["error_category"] = "auth_switch_error"
        rec["error_message"] = str(exc)[:300]
        return rec

    # ------------------------------------------------------------------
    # 2. Fetch credential (suppress output to avoid leaking secrets)
    # ------------------------------------------------------------------
    try:
        with quiet_stdout():
            token = fetch_credential(auth_method, ml_client, config["endpoint_name"])
    except Exception as exc:
        rec["error_category"] = "credential_error"
        rec["error_message"] = str(exc)[:300]
        return rec

    # ------------------------------------------------------------------
    # 3. Pick random inputs and call the endpoint
    # ------------------------------------------------------------------
    inputs, payload = pick_random_inputs(config["payload_format"])
    rec["input_count"] = len(inputs)
    call_start = time.time()
    try:
        result = invoke_endpoint(config["scoring_uri"], token, payload)
        rec["success"] = True
        rec["http_status"] = result["status_code"]
        rec["response_ms"] = result["elapsed_ms"]
        rec["request_id"] = result["headers"].get("x-request-id")
        rec["ms_request_id"] = result["headers"].get("x-ms-request-id")
        rec["response_model"] = extract_model_name(result["response_body"])
    except requests.exceptions.HTTPError as exc:
        rec["response_ms"] = round((time.time() - call_start) * 1000, 1)
        rec["http_status"] = (
            exc.response.status_code if exc.response is not None else None
        )
        rec["error_category"] = "http_error"
        rec["error_message"] = str(exc)[:300]
    except requests.exceptions.RequestException as exc:
        rec["response_ms"] = round((time.time() - call_start) * 1000, 1)
        rec["error_category"] = type(exc).__name__
        rec["error_message"] = str(exc)[:300]
    except Exception as exc:
        rec["response_ms"] = round((time.time() - call_start) * 1000, 1)
        rec["error_category"] = type(exc).__name__
        rec["error_message"] = str(exc)[:300]

    return rec


# ===========================================================================
# HTML Report — SVG Charts
# ===========================================================================

def _esc(text) -> str:
    """HTML-escape a value, treating None as empty string."""
    return html_mod.escape(str(text)) if text is not None else ""


def _pie_svg(pass_count: int, fail_count: int) -> str:
    """Generate an inline SVG pie chart for pass vs fail."""
    total = pass_count + fail_count
    size = 220
    cx, cy, r = size / 2, size / 2, 80

    if total == 0:
        return (
            f'<svg width="{size}" height="{size}">'
            f'<text x="{cx}" y="{cy}" text-anchor="middle" fill="#999">'
            f"No data</text></svg>"
        )

    if fail_count == 0:
        return (
            f'<svg width="{size}" height="{size + 30}">'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#4CAF50"/>'
            f'<text x="{cx}" y="{cy}" text-anchor="middle" dy="0.35em" '
            f'fill="white" font-size="18" font-weight="bold">{pass_count}</text>'
            f'<text x="{cx}" y="{size + 18}" text-anchor="middle" '
            f'font-size="12" fill="#333">100% Pass</text></svg>'
        )

    if pass_count == 0:
        return (
            f'<svg width="{size}" height="{size + 30}">'
            f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="#f44336"/>'
            f'<text x="{cx}" y="{cy}" text-anchor="middle" dy="0.35em" '
            f'fill="white" font-size="18" font-weight="bold">{fail_count}</text>'
            f'<text x="{cx}" y="{size + 18}" text-anchor="middle" '
            f'font-size="12" fill="#333">100% Fail</text></svg>'
        )

    # Two-segment pie
    pass_frac = pass_count / total
    angle = pass_frac * 2 * math.pi

    # Start at 12 o'clock, sweep clockwise
    sx, sy = cx, cy - r
    ex = cx + r * math.sin(angle)
    ey = cy - r * math.cos(angle)
    large_pass = 1 if angle > math.pi else 0
    large_fail = 1 if (2 * math.pi - angle) > math.pi else 0

    pp = f"M {cx},{cy} L {sx},{sy} A {r},{r} 0 {large_pass} 1 {ex:.2f},{ey:.2f} Z"
    fp = f"M {cx},{cy} L {ex:.2f},{ey:.2f} A {r},{r} 0 {large_fail} 1 {sx},{sy} Z"
    pass_pct = round(pass_frac * 100, 1)
    fail_pct = round(100 - pass_pct, 1)

    return (
        f'<svg width="{size}" height="{size + 40}">'
        f'<path d="{pp}" fill="#4CAF50"/>'
        f'<path d="{fp}" fill="#f44336"/>'
        f'<rect x="10" y="{size + 8}" width="14" height="14" rx="2" fill="#4CAF50"/>'
        f'<text x="30" y="{size + 20}" font-size="12">Pass {pass_count} ({pass_pct}%)</text>'
        f'<rect x="{cx}" y="{size + 8}" width="14" height="14" rx="2" fill="#f44336"/>'
        f'<text x="{cx + 20}" y="{size + 20}" font-size="12">'
        f"Fail {fail_count} ({fail_pct}%)</text></svg>"
    )


def _histogram_svg(results: list[dict], bucket_seconds: int) -> str:
    """Generate an inline SVG stacked histogram of pass/fail per time bucket."""
    if not results:
        return "<p>No data for histogram.</p>"

    times = [datetime.fromisoformat(r["timestamp"]) for r in results]
    min_t = min(times)

    # Bucket results by time window
    buckets: dict[int, dict] = {}
    for i, r in enumerate(results):
        idx = int((times[i] - min_t).total_seconds() // max(bucket_seconds, 1))
        if idx not in buckets:
            buckets[idx] = {"pass": 0, "fail": 0, "label": "", "models": set()}
        if r["success"]:
            buckets[idx]["pass"] += 1
        else:
            buckets[idx]["fail"] += 1
        model_key = r.get("model_label") or r.get("response_model") or ""
        if model_key:
            buckets[idx]["models"].add(model_key)
        if not buckets[idx]["label"]:
            bt = min_t + timedelta(seconds=idx * bucket_seconds)
            buckets[idx]["label"] = bt.strftime("%H:%M:%S")

    if not buckets:
        return "<p>No data for histogram.</p>"

    max_idx = max(buckets.keys())
    num = max_idx + 1
    max_count = max((b["pass"] + b["fail"]) for b in buckets.values())

    # Layout constants
    ml, mr, mt, mb = 50, 20, 20, 80
    bw = max(20, min(50, 600 // max(num, 1)))
    gap = 4
    chart_w = ml + num * (bw + gap) + mr
    chart_h = 300
    plot_h = chart_h - mt - mb
    scale = plot_h / max(max_count, 1)

    parts: list[str] = [
        f'<svg width="{max(chart_w, 200)}" height="{chart_h}" '
        f'style="font-family:sans-serif;">'
    ]

    # Y-axis gridlines
    tick_step = max(1, max_count // 5)
    for tv in range(0, max_count + 1, tick_step):
        y = chart_h - mb - tv * scale
        parts.append(
            f'<line x1="{ml}" y1="{y:.1f}" x2="{chart_w - mr}" y2="{y:.1f}" '
            f'stroke="#e0e0e0" stroke-width="1"/>'
        )
        parts.append(
            f'<text x="{ml - 5}" y="{y + 4:.1f}" text-anchor="end" '
            f'font-size="10" fill="#666">{tv}</text>'
        )

    # Axes
    parts.append(
        f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{chart_h - mb}" stroke="#333"/>'
    )
    parts.append(
        f'<line x1="{ml}" y1="{chart_h - mb}" x2="{chart_w - mr}" '
        f'y2="{chart_h - mb}" stroke="#333"/>'
    )

    # Bars
    for i in range(num):
        b = buckets.get(i, {"pass": 0, "fail": 0, "label": "", "models": set()})
        x = ml + i * (bw + gap) + gap
        base = chart_h - mb
        ph = b["pass"] * scale
        fh = b["fail"] * scale
        model_str = ", ".join(sorted(b.get("models", set()))) or "N/A"

        if ph > 0:
            parts.append(
                f'<rect x="{x}" y="{base - ph:.1f}" width="{bw}" '
                f'height="{ph:.1f}" fill="#4CAF50">'
                f"<title>Pass: {b['pass']}, Models: {_esc(model_str)}</title>"
                f"</rect>"
            )
        if fh > 0:
            parts.append(
                f'<rect x="{x}" y="{base - ph - fh:.1f}" width="{bw}" '
                f'height="{fh:.1f}" fill="#f44336">'
                f"<title>Fail: {b['fail']}, Models: {_esc(model_str)}</title>"
                f"</rect>"
            )

        total = b["pass"] + b["fail"]
        if total:
            parts.append(
                f'<text x="{x + bw / 2}" y="{base - ph - fh - 4:.1f}" '
                f'text-anchor="middle" font-size="9" fill="#333">{total}</text>'
            )

        label = b["label"] or f"t+{i * bucket_seconds}s"
        lx = x + bw / 2
        ly = chart_h - mb + 14
        parts.append(
            f'<text x="{lx}" y="{ly}" text-anchor="end" font-size="9" '
            f'fill="#333" transform="rotate(-45 {lx} {ly})">'
            f"{_esc(label)}</text>"
        )

    parts.append("</svg>")
    return "\n".join(parts)


# ===========================================================================
# HTML Report — Generator
# ===========================================================================

def generate_html_report(
    results: list[dict],
    output_dir: Path,
    bucket_seconds: int,
    source_ip: str,
    config: dict,
) -> Path:
    """Write report.html into *output_dir* and return its path."""
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    overall = group_stats(results)
    ep_name = config.get("endpoint_name", "N/A")

    # Breakdowns
    by_auth: dict[str, list[dict]] = {}
    by_model: dict[str, list[dict]] = {}
    for r in results:
        by_auth.setdefault(r["auth_method"], []).append(r)
        mk = r["model_label"] or r["response_model"] or "N/A"
        by_model.setdefault(mk, []).append(r)

    def _breakdown_table(groups: dict[str, list[dict]]) -> str:
        rows: list[str] = []
        for name, recs in sorted(groups.items()):
            s = group_stats(recs)
            rows.append(
                f'<tr><td>{_esc(name)}</td><td>{s["total"]}</td>'
                f'<td class="pass">{s["passes"]}</td>'
                f'<td class="fail">{s["fails"]}</td>'
                f'<td>{s["pass_rate"]}%</td><td>{s["avg_ms"]}</td>'
                f'<td>{s["p50_ms"]}</td><td>{s["p95_ms"]}</td></tr>'
            )
        return (
            "<table><tr><th>Name</th><th>Total</th><th>Pass</th><th>Fail</th>"
            "<th>Pass&nbsp;%</th><th>Avg&nbsp;ms</th><th>p50&nbsp;ms</th>"
            "<th>p95&nbsp;ms</th></tr>"
            + "".join(rows)
            + "</table>"
        )

    auth_table = _breakdown_table(by_auth)
    model_table = _breakdown_table(by_model)

    # Colour-coded detail rows
    detail_rows: list[str] = []
    for r in results:
        cls = "pass-row" if r["success"] else "fail-row"
        status = "PASS" if r["success"] else "FAIL"
        err = _esc(r["error_message"]) if r["error_message"] else ""
        model_disp = r["model_label"] or r["response_model"] or "N/A"
        detail_rows.append(
            f'<tr class="{cls}">'
            f'<td>{r["iteration"]}</td>'
            f'<td>{_esc(r["timestamp"])}</td>'
            f'<td>{_esc(r["auth_method"])}</td>'
            f"<td>{_esc(model_disp)}</td>"
            f"<td>{status}</td>"
            f'<td>{r["http_status"] or ""}</td>'
            f'<td>{r["response_ms"]:.0f}</td>'
            f'<td class="reqid">{_esc(r["request_id"] or "")}</td>'
            f'<td>{_esc(source_ip)}</td>'
            f'<td class="errmsg">{err}</td>'
            f"</tr>"
        )

    pie = _pie_svg(overall["passes"], overall["fails"])
    histogram = _histogram_svg(results, bucket_seconds)

    html = f"""\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Soak Test Report &mdash; {_esc(ep_name)}</title>
<style>
body {{ font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;
       margin:2em; background:#fafafa; color:#333; }}
h1 {{ color:#1a237e; }}
h2 {{ color:#283593; margin-top:2em; }}
.meta {{ color:#666; font-size:0.9em; margin-bottom:1.5em; }}
.cards {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(140px,1fr));
          gap:1em; margin:1.5em 0; }}
.card {{ background:#fff; border-radius:8px; padding:1em;
         box-shadow:0 1px 3px rgba(0,0,0,.12); text-align:center; }}
.card .val {{ font-size:2em; font-weight:700; }}
.card .lbl {{ color:#666; font-size:.85em; }}
.pass {{ color:#4CAF50; }}
.fail {{ color:#f44336; }}
.charts {{ display:flex; flex-wrap:wrap; gap:2em; margin:2em 0; }}
.chart-box {{ background:#fff; border-radius:8px; padding:1em;
              box-shadow:0 1px 3px rgba(0,0,0,.12); overflow-x:auto; }}
table {{ border-collapse:collapse; width:100%; margin:1em 0; font-size:.9em; }}
th,td {{ border:1px solid #ddd; padding:6px 10px; text-align:left; }}
th {{ background:#e8eaf6; position:sticky; top:0; }}
tr:nth-child(even) {{ background:#f5f5f5; }}
.pass-row {{ background:#e8f5e9 !important; }}
.fail-row {{ background:#ffebee !important; }}
.detail-wrap {{ max-height:600px; overflow:auto; border:1px solid #ddd;
                border-radius:4px; }}
.reqid {{ font-size:0.8em; word-break:break-all; }}
.errmsg {{ font-size:0.8em; color:#c62828; max-width:300px;
           overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }}
</style>
</head>
<body>
<h1>Soak Test Report</h1>
<p class="meta">
  Endpoint: <strong>{_esc(ep_name)}</strong> &middot;
  Generated: {now}
</p>

<div class="cards">
  <div class="card"><div class="val">{overall["total"]}</div>
       <div class="lbl">Total</div></div>
  <div class="card"><div class="val pass">{overall["passes"]}</div>
       <div class="lbl">Passed</div></div>
  <div class="card"><div class="val fail">{overall["fails"]}</div>
       <div class="lbl">Failed</div></div>
  <div class="card"><div class="val">{overall["pass_rate"]}%</div>
       <div class="lbl">Pass Rate</div></div>
  <div class="card"><div class="val">{overall["avg_ms"]}</div>
       <div class="lbl">Avg ms</div></div>
  <div class="card"><div class="val">{overall["p50_ms"]}</div>
       <div class="lbl">p50 ms</div></div>
  <div class="card"><div class="val">{overall["p95_ms"]}</div>
       <div class="lbl">p95 ms</div></div>
</div>

<div class="charts">
  <div class="chart-box"><h3>Pass / Fail</h3>{pie}</div>
  <div class="chart-box"><h3>Iterations per Time Bucket ({bucket_seconds}s)</h3>
       {histogram}</div>
</div>

<h2>Breakdown by Auth Method</h2>
{auth_table}

<h2>Breakdown by Model</h2>
{model_table}

<h2>Detailed Results</h2>
<div class="detail-wrap">
<table>
<tr><th>#</th><th>Timestamp</th><th>Auth</th><th>Model</th>
    <th>Status</th><th>HTTP</th><th>ms</th><th>Request&nbsp;ID</th>
    <th>Source&nbsp;IP</th><th>Error</th></tr>
{"".join(detail_rows)}
</table>
</div>
</body>
</html>"""

    path = output_dir / "report.html"
    path.write_text(html, encoding="utf-8")
    return path


# ===========================================================================
# Main
# ===========================================================================

def main() -> None:
    """Entry point — parse args, configure, run soak loop, write report."""
    args = parse_args()

    print("\n" + "=" * 55)
    print("  Azure AI Foundry — Soak / Prolonged Endpoint Test")
    print("=" * 55 + "\n")

    # ------------------------------------------------------------------
    # Output directory
    # ------------------------------------------------------------------
    if args.output_dir:
        out = Path(args.output_dir)
    else:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        out = Path("soak_results") / ts
    out.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    # Interactive config (reuses quick-script prompts)
    # ------------------------------------------------------------------
    config = prompt_config()
    if not config["scoring_uri"]:
        print("\nERROR: Inference target URI is required.")
        sys.exit(1)

    if not has_workspace_details(config):
        print(
            "\nERROR: Workspace details are required for authMode switching "
            "and credential retrieval."
        )
        sys.exit(1)

    # ------------------------------------------------------------------
    # ML Client
    # ------------------------------------------------------------------
    print("\nConnecting to AI Foundry project workspace...")
    try:
        credential = DefaultAzureCredential()
        ml_client = MLClient(
            credential=credential,
            subscription_id=config["subscription_id"],
            resource_group_name=config["resource_group"],
            workspace_name=config["workspace_name"],
        )
        print("  Connected.")
    except Exception as exc:
        print(f"  Connection failed: {exc}")
        sys.exit(1)

    # ------------------------------------------------------------------
    # Input text — randomly picked from defaults each iteration
    # ------------------------------------------------------------------
    print(f"\n  Payload format : {config['payload_format']}")
    print(f"  Input pool     : {len(DEFAULT_INPUTS)} default samples")
    print(f"  (1-{len(DEFAULT_INPUTS)} samples picked randomly per iteration)")

    # ------------------------------------------------------------------
    # Source IP
    # ------------------------------------------------------------------
    print("\nResolving source IP...")
    source_ip = get_source_ip()
    print(f"  Source IP: {source_ip}")

    # ------------------------------------------------------------------
    # Pre-flight check
    # ------------------------------------------------------------------
    try:
        preflight_check(ml_client, config["endpoint_name"])
    except RuntimeError as exc:
        print(f"\n  PRE-FLIGHT FAILED: {exc}")
        sys.exit(1)

    # ------------------------------------------------------------------
    # Parse auth methods + model labels
    # ------------------------------------------------------------------
    auth_list = [a.strip().lower() for a in args.auth.split(",") if a.strip()]
    for a in auth_list:
        if a not in AUTH_MODE_MAP:
            print(f"ERROR: Unknown auth method '{a}'. Choose from: key, aad, aml")
            sys.exit(1)

    model_list: list[str | None] = (
        [m.strip() for m in args.models.split(",") if m.strip()]
        if args.models
        else [None]
    )

    auth_iter = cycle(auth_list)
    model_iter = cycle(model_list)

    # ------------------------------------------------------------------
    # Record original authMode for restoration
    # ------------------------------------------------------------------
    original_auth = get_current_auth_mode(ml_client, config["endpoint_name"])
    current_auth = original_auth

    # ------------------------------------------------------------------
    # Signal handler for graceful Ctrl+C
    # ------------------------------------------------------------------
    shutdown = False

    def on_sigint(sig, frame):
        nonlocal shutdown
        if shutdown:
            sys.exit(1)  # second Ctrl+C → force quit
        shutdown = True
        print("\n\n  Ctrl+C — stopping after current iteration...")

    signal.signal(signal.SIGINT, on_sigint)

    # ------------------------------------------------------------------
    # Print run plan
    # ------------------------------------------------------------------
    limit_parts: list[str] = []
    if args.duration_seconds:
        limit_parts.append(f"{args.duration_seconds}s")
    if args.max_tests:
        limit_parts.append(f"{args.max_tests} iterations")
    if not limit_parts:
        limit_parts.append("until Ctrl+C")

    print(f"\n{'=' * 55}")
    print(f"  Run plan     : {' or '.join(limit_parts)}")
    print(f"  Auth rotation: {' -> '.join(a.upper() for a in auth_list)}")
    if model_list != [None]:
        print(f"  Model rotation: {' -> '.join(str(m) for m in model_list)}")
    print(f"  Output       : {out}")
    print(f"{'=' * 55}\n")

    max_label = str(args.max_tests) if args.max_tests else "\u221e"

    # ------------------------------------------------------------------
    # Main soak loop
    # ------------------------------------------------------------------
    results: list[dict] = []
    jsonl_path = out / "results.jsonl"
    run_start = time.time()
    idx = 0

    try:
        while not shutdown:
            # Check stop conditions
            if args.max_tests is not None and idx >= args.max_tests:
                break
            if (
                args.duration_seconds is not None
                and (time.time() - run_start) >= args.duration_seconds
            ):
                break

            idx += 1
            auth = next(auth_iter)
            model = next(model_iter)

            rec = do_iteration(
                idx, auth, model, config, ml_client, current_auth,
            )

            # Track current authMode on the endpoint
            if rec["auth_switched"]:
                current_auth = AUTH_MODE_MAP[auth]

            results.append(rec)

            # Append to JSONL incrementally
            with open(jsonl_path, "a", encoding="utf-8") as f:
                f.write(json.dumps(rec) + "\n")

            # One-line console progress
            status = (
                "\033[32mPASS\033[0m"
                if rec["success"]
                else "\033[31mFAIL\033[0m"
            )
            err_hint = (
                f" {rec['error_category']}" if rec["error_category"] else ""
            )
            http = str(rec["http_status"] or "---")
            print(
                f"  [{idx:04d}/{max_label:>4s}] "
                f"{rec['timestamp'][:19]}Z  {rec['auth_method']:3s}  "
                f"{http:>3s}  {rec['response_ms']:>8.0f}ms  {status}{err_hint}"
            )

    finally:
        # --------------------------------------------------------------
        # Cleanup: restore authMode + generate report
        # --------------------------------------------------------------
        elapsed = time.time() - run_start
        print(f"\n{'=' * 55}")
        print(f"  Run finished — {idx} iteration(s) in {elapsed:.0f}s")

        if current_auth.lower() != original_auth.lower():
            print(f"  Restoring authMode to '{original_auth}'...")
            try:
                with quiet_stdout():
                    switch_auth_mode(
                        ml_client, config["endpoint_name"], original_auth,
                    )
                print("  Restored.")
            except Exception as exc:
                print(f"  WARNING: Could not restore authMode: {exc}")

        if results:
            report_path = generate_html_report(
                results, out, args.bucket_seconds, source_ip, config,
            )
            s = group_stats(results)
            print(
                f"\n  Total: {s['total']}  Pass: {s['passes']}  "
                f"Fail: {s['fails']}  Rate: {s['pass_rate']}%  "
                f"Avg: {s['avg_ms']}ms  p50: {s['p50_ms']}ms  "
                f"p95: {s['p95_ms']}ms"
            )
            print(f"\n  Results : {jsonl_path}")
            print(f"  Report  : {report_path}")
        else:
            print("  No iterations completed — no report generated.")

        print("=" * 55)


if __name__ == "__main__":
    main()
