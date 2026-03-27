"""
Quick Interactive Endpoint Test — Azure AI Foundry Managed Compute Endpoints.

A standalone interactive script to test any model deployed on Azure AI Foundry
Hub managed compute. Works with HuggingFace models (GTE embeddings, etc.)
served via managed online endpoints.

No Terraform state required — enter your inference target URI or workspace
details interactively.

Key features:
    - Auto-switches endpoint authMode to match the selected test scenario
      (Key, AADToken, AMLToken) before calling the endpoint.
    - Auto-fetches credentials (key, AAD token, AML token) via Azure ML SDK.
    - Publishes source IP for Azure Monitor / App Insights log correlation.
    - Prints a structured test report with timing, request IDs, and auth details.
    - Offers to restore original authMode after the test completes.

AI Foundry publishes inference URIs in the format:
    https://<endpoint-name>.<region>.inference.ml.azure.com/v1/embeddings
    https://<endpoint-name>.<region>.inference.ml.azure.com/v1/chat/completions
    https://<endpoint-name>.<region>.inference.ml.azure.com/score

Workflow:
    1. Enter inference URI or workspace details.
    2. Endpoint name auto-extracted from URI.
    3. Choose input text: use built-in samples or type your own.
    4. Pick auth method: [1] Key  [2] AAD  [3] AML Token
    5. Script switches endpoint authMode → fetches credential → calls endpoint.
    6. Publishes source IP, response time, request IDs in a test report.
    7. Offers to restore original authMode.

Prerequisites:
    pip install -r requirements.txt   # azure-ai-ml, azure-identity, requests
    az login                          # or configure a managed identity

Usage:
    python tests/test_endpoint_quick.py
"""

import json
import re
import socket
import sys
import time
from datetime import datetime, timezone

try:
    import requests
    from azure.identity import DefaultAzureCredential
    from azure.ai.ml import MLClient
except ImportError as exc:
    print(f"Missing dependency: {exc.name}")
    print("Install with:  pip install azure-ai-ml azure-identity requests")
    sys.exit(1)


# =============================================================================
# Default sample inputs — GTE embedding model
# =============================================================================
DEFAULT_INPUTS = [
    "Terraform provisions Azure infrastructure as code.",
    "Azure AI Foundry hosts managed ML endpoints.",
    "HuggingFace GTE models generate text embeddings.",
]


# =============================================================================
# URI parsing helpers
# =============================================================================

def extract_endpoint_name(scoring_uri: str) -> str:
    """Extract the endpoint name from an AI Foundry inference URI.

    AI Foundry managed endpoints publish URIs in the format:
        https://<endpoint-name>.<region>.inference.ml.azure.com/<path>

    Args:
        scoring_uri: Full inference URI.

    Returns:
        Endpoint name (subdomain), or empty string if parsing fails.

    Examples:
        >>> extract_endpoint_name("https://my-endpoint.australiaeast.inference.ml.azure.com/v1/embeddings")
        'my-endpoint'
        >>> extract_endpoint_name("https://ep-proj-gte.eastus.inference.ml.azure.com/score")
        'ep-proj-gte'
    """
    match = re.match(r"https://([^.]+)\.\S+\.inference\.ml\.azure\.com", scoring_uri)
    return match.group(1) if match else ""


def detect_payload_format(scoring_uri: str) -> str:
    """Detect the expected payload format from the inference URI path.

    AI Foundry endpoints support multiple API paths:
        /v1/embeddings          -> OpenAI-compatible embeddings API
        /v1/chat/completions    -> OpenAI-compatible chat API
        /score                  -> Custom scoring (legacy format)

    Args:
        scoring_uri: Full inference URI.

    Returns:
        One of: 'embeddings', 'chat', 'score'.
    """
    if "/v1/embeddings" in scoring_uri:
        return "embeddings"
    elif "/v1/chat/completions" in scoring_uri:
        return "chat"
    else:
        return "score"


# =============================================================================
# Interactive configuration
# =============================================================================

def prompt_config() -> dict:
    """Prompt user for endpoint configuration interactively.

    Offers two paths:
      [1] Enter inference target URI directly
          -> endpoint name auto-extracted from URI
          -> workspace details prompted for Key/AML auth (optional)
      [2] Enter workspace details (subscription, RG, AI Foundry project,
          endpoint name) -> scoring URI auto-resolved via Azure ML SDK

    Returns:
        dict with keys: subscription_id, resource_group, workspace_name,
        endpoint_name, scoring_uri, payload_format.
    """
    print("  How do you want to connect?\n")
    print("  [1] Enter inference target URI directly")
    print("      (e.g. https://<endpoint-name>.<region>.inference.ml.azure.com/v1/embeddings)")
    print()
    print("  [2] Enter workspace details (subscription, RG, AI Foundry project, endpoint)")
    print("      -> inference URI will be resolved automatically via Azure ML SDK")
    print()

    while True:
        mode = input("  Choice (1/2): ").strip()
        if mode in ("1", "2"):
            break
        print("  Please enter 1 or 2.")

    config = {
        "subscription_id": "",
        "resource_group": "",
        "workspace_name": "",
        "endpoint_name": "",
        "scoring_uri": "",
        "payload_format": "embeddings",
    }

    if mode == "1":
        # Direct inference URI
        print()
        config["scoring_uri"] = input(
            "  Inference Target URI: "
        ).strip()

        # Auto-extract endpoint name from URI
        config["endpoint_name"] = extract_endpoint_name(config["scoring_uri"])
        config["payload_format"] = detect_payload_format(config["scoring_uri"])

        if config["endpoint_name"]:
            print(f"  Endpoint name (auto-detected): {config['endpoint_name']}")
        else:
            print("  WARNING: Could not extract endpoint name from URI.")

        print(f"  Payload format (auto-detected): {config['payload_format']}")

        # Workspace details for Key and AML token auth
        print("\n  Workspace details for Key/AML token auto-retrieval:")
        print("  (Press Enter to skip — you can paste a key manually later)\n")
        config["subscription_id"] = input(
            "  Subscription ID  [e.g. 00000000-0000-0000-0000-000000000000]: "
        ).strip()
        config["resource_group"] = input(
            "  Resource Group   [e.g. rg-my-project]: "
        ).strip()
        config["workspace_name"] = input(
            "  AI Foundry Project name [e.g. my-ai-project]: "
        ).strip()

    else:
        # Workspace details -> auto-resolve scoring URI
        print()
        config["subscription_id"] = input(
            "  Subscription ID         [e.g. 00000000-0000-0000-0000-000000000000]: "
        ).strip()
        config["resource_group"] = input(
            "  Resource Group           [e.g. rg-my-project]: "
        ).strip()
        config["workspace_name"] = input(
            "  AI Foundry Project name  [e.g. my-ai-project]: "
        ).strip()
        config["endpoint_name"] = input(
            "  Endpoint name            [e.g. ep-my-project-gte]: "
        ).strip()

        if not all([config["subscription_id"], config["resource_group"],
                    config["workspace_name"], config["endpoint_name"]]):
            print("\n  ERROR: All four fields are required for auto-resolve.")
            sys.exit(1)

        print("\n  Resolving inference URI via Azure ML SDK...")
        try:
            credential = DefaultAzureCredential()
            ml_client = MLClient(
                credential=credential,
                subscription_id=config["subscription_id"],
                resource_group_name=config["resource_group"],
                workspace_name=config["workspace_name"],
            )
            ep = ml_client.online_endpoints.get(config["endpoint_name"])
            config["scoring_uri"] = ep.scoring_uri
            config["payload_format"] = detect_payload_format(config["scoring_uri"])
            print(f"  Inference URI: {config['scoring_uri']}")
            print(f"  Payload format (auto-detected): {config['payload_format']}")
        except Exception as exc:
            print(f"  Auto-resolve failed: {exc}")
            config["scoring_uri"] = input("  Enter inference URI manually: ").strip()
            config["endpoint_name"] = extract_endpoint_name(config["scoring_uri"])
            config["payload_format"] = detect_payload_format(config["scoring_uri"])

    print("-" * 50)
    return config


def has_workspace_details(config: dict) -> bool:
    """Check whether the config has all workspace details for SDK calls.

    Args:
        config: Configuration dict from prompt_config().

    Returns:
        True if subscription_id, resource_group, workspace_name, and
        endpoint_name are all non-empty.
    """
    return all([
        config.get("subscription_id"),
        config.get("resource_group"),
        config.get("workspace_name"),
        config.get("endpoint_name"),
    ])


# =============================================================================
# Source IP resolution
# =============================================================================

def get_source_ip() -> str:
    """Resolve the public IP of this machine for Azure log correlation.

    Tries external services to get the public IP. Falls back to the local
    hostname IP if external resolution fails.

    Returns:
        Public IP address string, or local IP as fallback.
    """
    # Try external services (fast, plain-text responses)
    for url in ["https://api.ipify.org", "https://ifconfig.me/ip"]:
        try:
            resp = requests.get(url, timeout=5)
            if resp.status_code == 200:
                return resp.text.strip()
        except Exception:
            continue

    # Fallback: local IP via socket
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "unknown"


# =============================================================================
# Endpoint authMode switching
# =============================================================================

# Mapping from menu choice to Azure ML SDK auth_mode values.
# SDK uses lowercase with underscores: 'key', 'aml_token', 'aad_token'
# Ref: https://learn.microsoft.com/en-us/azure/machine-learning/how-to-authenticate-online-endpoint
AUTH_MODE_MAP = {
    "key": "key",
    "aad": "aad_token",
    "aml": "aml_token",
}


def get_current_auth_mode(ml_client: MLClient, endpoint_name: str) -> str:
    """Get the current authMode of the managed online endpoint.

    Args:
        ml_client:     Authenticated MLClient connected to the AI Foundry project.
        endpoint_name: Name of the managed online endpoint.

    Returns:
        Current authMode string (e.g. 'Key', 'AADToken', 'AMLToken').
    """
    ep = ml_client.online_endpoints.get(endpoint_name)
    return ep.auth_mode


def _ensure_traffic(ml_client: MLClient, endpoint_name: str) -> None:
    """Ensure all deployments on the endpoint have 100% traffic.

    If only one deployment exists, it gets 100%. If multiple deployments
    exist and all have 0% traffic, traffic is distributed evenly.
    If traffic is already positive, no change is made.

    Args:
        ml_client:     Authenticated MLClient connected to the AI Foundry project.
        endpoint_name: Name of the managed online endpoint.
    """
    endpoint = ml_client.online_endpoints.get(endpoint_name)
    traffic = endpoint.traffic or {}

    # Check if any deployment has positive traffic
    if traffic and any(v > 0 for v in traffic.values()):
        print(f"  Traffic OK       : {dict(traffic)}")
        return

    # All deployments have 0% — fix by distributing evenly
    deployments = list(traffic.keys())
    if not deployments:
        # No deployments listed in traffic — list them via SDK
        dep_list = ml_client.online_deployments.list(endpoint_name)
        deployments = [d.name for d in dep_list]

    if not deployments:
        print("  WARNING: No deployments found on endpoint.")
        return

    if len(deployments) == 1:
        new_traffic = {deployments[0]: 100}
    else:
        share = 100 // len(deployments)
        new_traffic = {name: share for name in deployments}
        remainder = 100 - (share * len(deployments))
        if remainder > 0:
            new_traffic[deployments[0]] += remainder

    print(f"  Setting traffic  : {new_traffic}")
    endpoint.traffic = new_traffic
    poller = ml_client.online_endpoints.begin_create_or_update(endpoint)
    poller.wait()
    print(f"  Traffic updated  : {new_traffic}")


def preflight_check(ml_client: MLClient, endpoint_name: str) -> None:
    """Run pre-flight sanity checks before testing the endpoint.

    Verifies:
        1. Endpoint exists and provisioning state is 'Succeeded'.
        2. At least one deployment exists.
        3. All deployments are in 'Succeeded' provisioning state.
        4. Traffic is allocated to at least one deployment.

    Args:
        ml_client:     Authenticated MLClient connected to the AI Foundry project.
        endpoint_name: Name of the managed online endpoint.

    Raises:
        RuntimeError: If any check fails.
    """
    print("\n" + "=" * 50)
    print("  Pre-flight Sanity Check")
    print("=" * 50)

    # 1. Check endpoint exists and is healthy
    ep = ml_client.online_endpoints.get(endpoint_name)
    ep_state = ep.provisioning_state
    print(f"  Endpoint state   : {ep_state}")
    if ep_state != "Succeeded":
        raise RuntimeError(
            f"Endpoint provisioning state is '{ep_state}', expected 'Succeeded'. "
            f"Wait for provisioning to complete before testing."
        )

    # 2. Check deployments exist
    deployments = list(ml_client.online_deployments.list(endpoint_name))
    print(f"  Deployments      : {len(deployments)}")
    if not deployments:
        raise RuntimeError(
            "No deployments found on the endpoint. "
            "Deploy a model before testing."
        )

    # 3. Check deployment health
    for dep in deployments:
        dep_state = dep.provisioning_state
        print(f"    {dep.name:30s} state={dep_state}")
        if dep_state != "Succeeded":
            raise RuntimeError(
                f"Deployment '{dep.name}' state is '{dep_state}', expected 'Succeeded'."
            )

    # 4. Check and fix traffic
    print(f"  Current authMode : {ep.auth_mode}")
    _ensure_traffic(ml_client, endpoint_name)

    print("  Pre-flight       : ALL CHECKS PASSED")


def switch_auth_mode(ml_client: MLClient, endpoint_name: str, target_mode: str) -> str:
    """Switch the endpoint's authMode and ensure traffic is routed.

    Steps:
        1. Check current authMode — skip update if already matching.
        2. Update authMode on the full endpoint object.
        3. Ensure all deployments have positive traffic (fix 0% allocations).

    Args:
        ml_client:     Authenticated MLClient connected to the AI Foundry project.
        endpoint_name: Name of the managed online endpoint.
        target_mode:   Desired authMode ('Key', 'AADToken', or 'AMLToken').

    Returns:
        The previous authMode (for restore purposes).
    """
    current_mode = get_current_auth_mode(ml_client, endpoint_name)
    print(f"  Current authMode : {current_mode}")
    print(f"  Target authMode  : {target_mode}")

    if current_mode.lower() == target_mode.lower():
        print("  AuthMode already matches — no change needed.")
        # Still ensure traffic is routed
        _ensure_traffic(ml_client, endpoint_name)
        return current_mode

    print(f"  Switching endpoint authMode to '{target_mode}'...")
    endpoint = ml_client.online_endpoints.get(endpoint_name)
    endpoint.auth_mode = target_mode
    poller = ml_client.online_endpoints.begin_create_or_update(endpoint)
    poller.wait()
    print(f"  AuthMode switched to '{target_mode}'.")

    # Ensure traffic is set to 100% after the update
    _ensure_traffic(ml_client, endpoint_name)

    return current_mode


# =============================================================================
# Credential fetchers
# =============================================================================

def fetch_endpoint_key(ml_client: MLClient, endpoint_name: str) -> str:
    """Retrieve the primary endpoint key via Azure ML SDK.

    Calls MLClient.online_endpoints.get_keys() to fetch the key registered
    on the managed online endpoint in the AI Foundry project.

    If the SDK call fails (e.g. insufficient RBAC), falls back to an
    interactive prompt so the user can paste a key manually.

    Args:
        ml_client:     Authenticated MLClient connected to the AI Foundry project.
        endpoint_name: Name of the managed online endpoint.

    Returns:
        Endpoint primary key string.
    """
    print("\n  Retrieving endpoint key via Azure ML SDK...")
    try:
        keys = ml_client.online_endpoints.get_keys(endpoint_name)
        if hasattr(keys, "primary_key") and keys.primary_key:
            key = keys.primary_key
            print(f"  Key (first 8 chars): {key[:8]}...")
            return key
    except Exception as exc:
        print(f"  Auto-retrieve failed: {exc}")

    # Fallback: prompt user
    key = input("  Paste endpoint key manually: ").strip()
    return key


def fetch_aad_token() -> str:
    """Obtain an Azure AD (Entra ID) Bearer token for the ML scoring scope.

    Uses DefaultAzureCredential which tries (in order):
      - EnvironmentCredential
      - ManagedIdentityCredential
      - AzureCliCredential (az login)

    The token is scoped to the Azure ML service audience.

    Returns:
        AAD token string.
    """
    print("\n  Acquiring AAD token via DefaultAzureCredential...")
    credential = DefaultAzureCredential()
    token = credential.get_token("https://ml.azure.com/.default")
    print(f"  AAD token (first 20 chars): {token.token[:20]}...")
    print(f"  Expires at: {token.expires_on}")
    return token.token


def fetch_aml_token(ml_client: MLClient, endpoint_name: str) -> str:
    """Retrieve an AML workspace-scoped token for the online endpoint.

    Calls MLClient.online_endpoints.get_keys() on the AI Foundry project.
    Returns either an access_token (authMode=AMLToken) or primary_key
    (authMode=Key), whichever is available.

    Args:
        ml_client:     Authenticated MLClient connected to the AI Foundry project.
        endpoint_name: Name of the managed online endpoint.

    Returns:
        AML token or key string.
    """
    print("\n  Fetching AML token via Azure ML SDK...")
    keys = ml_client.online_endpoints.get_keys(endpoint_name)
    if hasattr(keys, "access_token") and keys.access_token:
        token = keys.access_token
        print(f"  AML token (first 20 chars): {token[:20]}...")
        return token
    elif hasattr(keys, "primary_key") and keys.primary_key:
        token = keys.primary_key
        print(f"  (Endpoint uses Key auth — retrieved primary key)")
        print(f"  Key (first 8 chars): {token[:8]}...")
        return token
    else:
        raise RuntimeError("Could not retrieve AML token or key from endpoint.")


# =============================================================================
# Input text and payload
# =============================================================================

def prompt_input_text() -> list:
    """Prompt user to enter custom input text or use defaults.

    Shows the default sample inputs and lets the user choose to use them
    or type custom text. Multiple custom lines can be entered one by one.

    Returns:
        List of input strings for the embedding model.
    """
    print("\n" + "=" * 50)
    print("  Input Text for Embedding")
    print("=" * 50)
    print("\n  Default samples:")
    for i, text in enumerate(DEFAULT_INPUTS, 1):
        print(f"    [{i}] {text}")

    choice = input("\n  Use defaults? (Y/n): ").strip().lower()
    if choice in ("", "y", "yes"):
        print("  Using default samples.")
        return DEFAULT_INPUTS

    print("\n  Enter custom text (one per line, empty line to finish):")
    custom = []
    while True:
        line = input("    > ").strip()
        if not line:
            break
        custom.append(line)

    if not custom:
        print("  No input provided — falling back to defaults.")
        return DEFAULT_INPUTS

    print(f"  Using {len(custom)} custom input(s).")
    return custom


def build_payload(inputs: list, fmt: str) -> dict:
    """Build the scoring request payload matching the endpoint's API format.

    AI Foundry managed endpoints expose different API paths:

    - /v1/embeddings (OpenAI-compatible):
        {"input": ["text1", "text2"]}

    - /v1/chat/completions (OpenAI-compatible):
        {"messages": [{"role": "user", "content": "text"}]}

    - /score (custom managed endpoint):
        {"input_data": {"input_string": ["text1", "text2"]}}

    Args:
        inputs: List of text strings.
        fmt:    Payload format — 'embeddings', 'chat', or 'score'.

    Returns:
        JSON-serialisable payload dict.
    """
    if fmt == "embeddings":
        return {"input": inputs}
    elif fmt == "chat":
        return {
            "messages": [{"role": "user", "content": text} for text in inputs]
        }
    else:
        return {"input_data": {"input_string": inputs}}


# =============================================================================
# Endpoint invocation
# =============================================================================

def invoke_endpoint(scoring_uri: str, token: str, payload: dict) -> dict:
    """Send a scoring request to the AI Foundry managed online endpoint.

    Captures response time, status code, and headers for the test report.

    Args:
        scoring_uri: Full inference target URI.
        token:       Bearer token (endpoint key, AAD token, or AML token).
        payload:     JSON-serialisable request body matching the API format.

    Returns:
        dict with keys: status_code, elapsed_ms, response_body, headers.

    Raises:
        requests.HTTPError: On non-2xx status codes.
    """
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }
    start = time.time()
    response = requests.post(
        scoring_uri,
        headers=headers,
        json=payload,
        timeout=120,
    )
    elapsed_ms = (time.time() - start) * 1000
    response.raise_for_status()
    return {
        "status_code": response.status_code,
        "elapsed_ms": round(elapsed_ms, 1),
        "response_body": response.json(),
        "headers": dict(response.headers),
    }


def print_result(result: dict) -> None:
    """Pretty-print the endpoint response, truncating long embedding vectors."""
    print("\n--- Response Body ---")
    formatted = json.dumps(result, indent=2)
    if len(formatted) > 2000:
        print(formatted[:2000])
        print(f"\n... (truncated, total {len(formatted)} chars)")
    else:
        print(formatted)
    print("--- End ---")


def print_test_report(
    scenario: str,
    source_ip: str,
    scoring_uri: str,
    endpoint_name: str,
    auth_mode: str,
    inputs: list,
    result: dict,
    timestamp: str,
) -> None:
    """Print a structured test report for log correlation and auditing.

    Args:
        scenario:      Auth scenario name (key/aad/aml).
        source_ip:     Public IP of the test client.
        scoring_uri:   Inference target URI.
        endpoint_name: Managed online endpoint name.
        auth_mode:     AuthMode set on the endpoint during the test.
        inputs:        List of input strings sent.
        result:        Result dict from invoke_endpoint().
        timestamp:     ISO timestamp when the test was initiated.
    """
    print("\n" + "=" * 60)
    print("  TEST REPORT")
    print("=" * 60)
    print(f"  Timestamp      : {timestamp}")
    print(f"  Source IP      : {source_ip}")
    print(f"  Endpoint       : {endpoint_name}")
    print(f"  Inference URI  : {scoring_uri}")
    print(f"  Auth Method    : {scenario.upper()}")
    print(f"  Auth Mode Set  : {auth_mode}")
    print(f"  Input Count    : {len(inputs)}")
    print(f"  HTTP Status    : {result['status_code']}")
    print(f"  Response Time  : {result['elapsed_ms']} ms")
    print(f"  Request ID     : {result['headers'].get('x-request-id', 'N/A')}")
    print(f"  MS Request ID  : {result['headers'].get('x-ms-request-id', 'N/A')}")
    print("=" * 60)
    print(f"\n  Use Source IP '{source_ip}' to filter Azure Monitor / App Insights logs.")
    print(f"  Use Request ID to trace this specific request in endpoint logs.")


# =============================================================================
# Interactive menu
# =============================================================================

def show_menu() -> str:
    """Display scenario menu and return user choice.

    Returns:
        One of: 'key', 'aad', 'aml'.
    """
    print("\n" + "=" * 50)
    print("  Select Authentication Method")
    print("=" * 50)
    print("  [1] Key   — Endpoint primary/secondary key")
    print("  [2] AAD   — Azure AD (Entra ID) token")
    print("  [3] AML   — AML workspace token via SDK")
    print("=" * 50)

    choice_map = {"1": "key", "2": "aad", "3": "aml"}
    while True:
        choice = input("\n  Enter choice (1/2/3): ").strip()
        if choice in choice_map:
            return choice_map[choice]
        print("  Invalid choice. Please enter 1, 2, or 3.")


# =============================================================================
# Main
# =============================================================================

def main() -> None:
    """Entry point — prompt config, pick scenario, auto-fetch creds, score."""
    print("\n" + "=" * 50)
    print("  Azure AI Foundry — Quick Endpoint Test")
    print("=" * 50 + "\n")

    # Step 1: Get endpoint configuration interactively
    config = prompt_config()
    scoring_uri = config["scoring_uri"]
    payload_format = config["payload_format"]

    if not scoring_uri:
        print("\nERROR: Inference target URI is required. Cannot continue.")
        sys.exit(1)

    # Step 2: Create ML client if workspace details are available
    ml_client = None
    if has_workspace_details(config):
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
            print(f"  Could not connect: {exc}")
            print("  (Key/AML token auto-retrieval won't be available)")
    else:
        print("\n  Workspace details not provided — Key/AML auto-retrieval disabled.")
        print("  You can still use AAD auth or paste a key manually.")

    # Step 3: Choose input text
    inputs = prompt_input_text()
    payload = build_payload(inputs, payload_format)

    print(f"\n  Payload format: {payload_format}")
    print(f"  Payload preview: {json.dumps(payload, indent=2)[:300]}")

    # Step 4: Resolve source IP for log correlation
    print("\nResolving source IP for Azure log correlation...")
    source_ip = get_source_ip()
    print(f"  Source IP: {source_ip}")

    # Step 5: Choose scenario
    scenario = show_menu()

    # Step 6: Require workspace details for authMode switching
    if not ml_client:
        print("\n  ERROR: Workspace details are required to switch authMode and")
        print("  auto-retrieve credentials. Re-run and provide workspace details.")
        sys.exit(1)

    # Step 6a: Pre-flight sanity check (endpoint health, deployments, traffic)
    try:
        preflight_check(ml_client, config["endpoint_name"])
    except RuntimeError as exc:
        print(f"\n  PRE-FLIGHT FAILED: {exc}")
        sys.exit(1)

    # Step 7: Switch authMode on the endpoint to match the selected scenario
    target_auth_mode = AUTH_MODE_MAP[scenario]
    print(f"\n{'=' * 50}")
    print(f"  Configuring endpoint for: {scenario.upper()} auth")
    print(f"{'=' * 50}")

    original_mode = None
    try:
        original_mode = switch_auth_mode(
            ml_client, config["endpoint_name"], target_auth_mode
        )
    except Exception as exc:
        print(f"\n  WARNING: Could not switch authMode: {exc}")
        print("  Proceeding with current endpoint configuration...")

    # Step 7a: Wait for Azure to propagate authMode + traffic changes
    print(f"\n  Waiting 15 seconds for Azure to propagate changes...")
    time.sleep(15)

    # Step 8: Auto-fetch credential
    print(f"\n{'=' * 50}")
    print(f"  Fetching credentials for: {scenario.upper()}")
    print(f"{'=' * 50}")

    try:
        if scenario == "key":
            token = fetch_endpoint_key(ml_client, config["endpoint_name"])
        elif scenario == "aad":
            token = fetch_aad_token()
        elif scenario == "aml":
            token = fetch_aml_token(ml_client, config["endpoint_name"])

        # Step 9: Invoke endpoint
        timestamp = datetime.now(timezone.utc).isoformat()
        print(f"\n  Calling endpoint: {scoring_uri}")
        print(f"  Payload: {len(inputs)} input string(s)")
        result = invoke_endpoint(scoring_uri, token, payload)
        print_result(result["response_body"])

        # Step 10: Publish test report
        print_test_report(
            scenario=scenario,
            source_ip=source_ip,
            scoring_uri=scoring_uri,
            endpoint_name=config["endpoint_name"],
            auth_mode=target_auth_mode,
            inputs=inputs,
            result=result,
            timestamp=timestamp,
        )
        print("\n  [PASS] Endpoint call succeeded.\n")
    except requests.exceptions.HTTPError as exc:
        print(f"\n  [FAIL] HTTP {exc.response.status_code}: {exc.response.text[:500]}")
        sys.exit(1)
    except Exception as exc:
        print(f"\n  [FAIL] {type(exc).__name__}: {exc}")
        sys.exit(1)
    finally:
        # Step 11: Offer to restore original authMode
        if original_mode and original_mode != target_auth_mode:
            print(f"\n  Original authMode was '{original_mode}'.")
            restore = input(f"  Restore to '{original_mode}'? (Y/n): ").strip().lower()
            if restore in ("", "y", "yes"):
                try:
                    switch_auth_mode(ml_client, config["endpoint_name"], original_mode)
                    print(f"  Restored authMode to '{original_mode}'.")
                except Exception as exc:
                    print(f"  WARNING: Could not restore authMode: {exc}")


if __name__ == "__main__":
    main()
