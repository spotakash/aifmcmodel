"""
Check which SKU types are supported for HuggingFace models in Azure ML Registry.
Uses azure-ai-ml SDK v2 to query model metadata directly.

Prerequisites:
    pip install azure-ai-ml azure-identity

Usage:
    python check_model_sku.py --model alibaba-nlp-gte-large-en-v1.5
    python check_model_sku.py --model alibaba-nlp-gte-multilingual-base
    python check_model_sku.py --filter alibaba-nlp-gte
    python check_model_sku.py --filter sentence-transformers
"""

import argparse
import json
import re
import sys

try:
    from azure.ai.ml import MLClient
    from azure.identity import DefaultAzureCredential
except ImportError:
    print("Missing dependencies. Install with:")
    print("  pip install azure-ai-ml azure-identity")
    sys.exit(1)


REGISTRY = "HuggingFace"


def get_registry_client() -> MLClient:
    """Create MLClient connected to the HuggingFace registry."""
    credential = DefaultAzureCredential()
    return MLClient(credential=credential, registry_name=REGISTRY)


def classify_sku(sku_name: str) -> str:
    """Classify a SKU as cpu or gpu based on Azure naming convention."""
    if re.match(r"Standard_N[CDV]", sku_name, re.IGNORECASE):
        return "gpu"
    return "cpu"


def pick_smallest_sku(skus: list) -> str:
    """Pick the smallest (cheapest) SKU from a list."""
    if not skus:
        return None

    def sort_key(sku):
        is_gpu = 1 if re.match(r"Standard_N[CDV]", sku, re.IGNORECASE) else 0
        nums = re.findall(r"(\d+)", sku)
        size = int(nums[0]) if nums else 99
        return (is_gpu, size)

    return sorted(skus, key=sort_key)[0]


def parse_compute_allow_list(tags: dict) -> list:
    """Extract SKU list from model tags."""
    for key in [
        "inference_compute_allow_list",
        "inference_supported_compute",
        "inferenceComputeAllowList",
        "inference_recommended_sku",
    ]:
        raw = tags.get(key)
        if not raw:
            continue

        if isinstance(raw, list):
            return [s.strip() for s in raw if s.strip()]
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, list):
                return [s.strip() for s in parsed if s.strip()]
        except (json.JSONDecodeError, TypeError):
            pass

        skus = re.split(r"[,\s]+", str(raw))
        return [s.strip() for s in skus if s.strip() and s.startswith("Standard_")]

    return []


# Engine template keywords that indicate GPU-backed inference
_GPU_ENGINE_KEYWORDS = [
    "gpu", "vllm", "hopper", "ampere", "ada", "tgi-gpu",
    "a100", "h100", "t4", "v100",
]
_CPU_ENGINE_KEYWORDS = ["cpu"]


def infer_sku_type_from_properties(properties: dict) -> tuple:
    """Infer SKU type from model catalog properties when available."""
    if not properties:
        return None, ""

    engine_id = str(properties.get("skuBasedEngineIds", "") or "").lower()
    if engine_id:
        has_gpu = any(kw in engine_id for kw in _GPU_ENGINE_KEYWORDS)
        has_cpu = any(kw in engine_id for kw in _CPU_ENGINE_KEYWORDS)
        source = f"catalog.skuBasedEngineIds: {properties.get('skuBasedEngineIds')}"

        if has_gpu and has_cpu:
            return "cpu+gpu", source
        if has_gpu:
            return "gpu", source
        if has_cpu:
            return "cpu", source

    return None, ""


def get_engine_template_from_properties(properties: dict) -> tuple:
    """Extract engine template name and full engine URI from catalog properties."""
    engine_uri = str((properties or {}).get("skuBasedEngineIds", "") or "").strip()
    if not engine_uri:
        return None, None

    match = re.search(r"/models/([^/]+)/", engine_uri)
    engine_template = match.group(1) if match else None
    return engine_template, engine_uri


# Map full engine template names to GPU architecture (checked first)
_ENGINE_TEMPLATE_GPU = {
    "vllm-hopper-sm":       "NVIDIA H100 80GB (Hopper)",
    "vllm-hopper-lg":       "NVIDIA H100 80GB (Hopper, multi-GPU)",
    "vllm-ampere-sm":       "NVIDIA A100 80GB (Ampere)",
    "vllm-ampere-lg":       "NVIDIA A100 80GB (Ampere, multi-GPU)",
    "tei-gpu-extra-small":  "NVIDIA T4 16GB (Turing)",
    "tei-gpu-small":        "NVIDIA T4 16GB (Turing)",
    "tei-gpu-single-sm":    "NVIDIA T4 16GB (Turing)",
    "tei-gpu-single-lg":    "NVIDIA A10/A100 (Ampere)",
    "tgi-gpu-sm":           "NVIDIA T4 16GB (Turing)",
    "tgi-gpu-lg":           "NVIDIA A100 80GB (Ampere)",
}

# Fallback: map engine template keywords to GPU architecture names
_ENGINE_GPU_ARCH_KEYWORDS = {
    "hopper": "NVIDIA H100 (Hopper)",
    "ada": "NVIDIA L4/L40 (Ada Lovelace)",
    "ampere": "NVIDIA A100/A10 (Ampere)",
    "a100": "NVIDIA A100 (Ampere)",
    "h100": "NVIDIA H100 (Hopper)",
    "t4": "NVIDIA T4 (Turing)",
    "v100": "NVIDIA V100 (Volta)",
}

# Map Azure GPU SKU families to GPU names
_SKU_GPU_NAMES = {
    "NC4as_T4":   "NVIDIA T4 16GB",
    "NC8as_T4":   "NVIDIA T4 16GB",
    "NC16as_T4":  "NVIDIA T4 16GB",
    "NC64as_T4":  "4x NVIDIA T4 16GB",
    "NC6s_v3":    "NVIDIA V100 16GB",
    "NC12s_v3":   "2x NVIDIA V100 16GB",
    "NC24s_v3":   "4x NVIDIA V100 16GB",
    "NC24ads_A100": "NVIDIA A100 80GB",
    "NC48ads_A100": "2x NVIDIA A100 80GB",
    "NC96ads_A100": "4x NVIDIA A100 80GB",
    "NC40ads_H100": "NVIDIA H100 80GB",
    "NC80adis_H100": "2x NVIDIA H100 80GB",
}


def _extract_model_size(name: str, tags: dict) -> str:
    """Extract model parameter count from name or tags."""
    # Check tags first
    for key in ["model_size", "num_parameters", "model_params"]:
        val = tags.get(key)
        if val:
            return str(val)

    # Extract from model name or modelId tag: e.g. "20b", "7B", "1.5b", "305m"
    sources = [name, tags.get("modelId", "")]
    for src in sources:
        m = re.search(r"(?:^|[-_/])(\d+(?:\.\d+)?[bBmM])(?:[-_/]|$)", src)
        if m:
            size = m.group(1).upper()
            if size.endswith("B"):
                return f"~{size} params"
            elif size.endswith("M"):
                return f"~{size} params"
    return None


def _infer_gpu_arch(engine_template: str, gpu_skus: list) -> str:
    """Infer GPU architecture from engine template or SKU list."""
    # Try exact engine template name first
    if engine_template:
        exact = _ENGINE_TEMPLATE_GPU.get(engine_template)
        if exact:
            return exact
        # Try keyword match in template name
        tpl = engine_template.lower()
        for keyword, arch in _ENGINE_GPU_ARCH_KEYWORDS.items():
            if keyword in tpl:
                return arch

    # Try to derive from SKU names
    if gpu_skus:
        for sku in gpu_skus:
            # Extract family: Standard_NC24ads_A100_v4 -> NC24ads_A100
            m = re.match(r"Standard_(NC\d+(?:s|as|ads|adis)?_[A-Za-z0-9]+)", sku)
            if m:
                family = m.group(1)
                for pattern, gpu_name in _SKU_GPU_NAMES.items():
                    if pattern in family:
                        return gpu_name
        # Fallback: at least list the SKUs
        return f"GPU (from SKU: {gpu_skus[0]})"

    return None


def analyze_model(name: str, version: str, tags: dict, properties: dict = None) -> dict:
    """Analyze model tags and return SKU recommendation from registry metadata."""
    result = {
        "model": name,
        "version": version,
        "uri": f"azureml://registries/{REGISTRY}/models/{name}/versions/{version}",
        "sku_type": None,
        "allowed_skus": [],
        "recommended_sku": None,
        "skus_by_type": {"cpu": [], "gpu": []},
        "min_gpu_mem_gb": 0,
        "confidence": "low",
        "source": "",
        "task": tags.get("task", tags.get("pipeline_tag", "unknown")),
        "engine_template": None,
        "engine_uri": None,
        "model_size": None,
        "gpu_arch": None,
    }

    engine_template, engine_uri = get_engine_template_from_properties(properties or {})
    result["engine_template"] = engine_template
    result["engine_uri"] = engine_uri
    result["model_size"] = _extract_model_size(name, tags)

    # --- 1. inference_compute_allow_list (highest reliability) ---
    allowed = parse_compute_allow_list(tags)
    if allowed:
        result["allowed_skus"] = allowed
        for sku in allowed:
            result["skus_by_type"][classify_sku(sku)].append(sku)

        has_cpu = bool(result["skus_by_type"]["cpu"])
        has_gpu = bool(result["skus_by_type"]["gpu"])

        if has_gpu and not has_cpu:
            result["sku_type"] = "gpu"
        elif has_cpu and not has_gpu:
            result["sku_type"] = "cpu"
        else:
            result["sku_type"] = "cpu+gpu"

        result["recommended_sku"] = pick_smallest_sku(allowed)
        result["confidence"] = "high"
        result["source"] = f"inference_compute_allow_list ({len(allowed)} SKUs)"
        result["gpu_arch"] = _infer_gpu_arch(engine_template, result["skus_by_type"]["gpu"])
        return result

    # --- 2. min GPU memory tag ---
    for key in ["min_inference_gpu_mem_in_gb", "min_gpu_memory_gb"]:
        val = tags.get(key)
        if val:
            try:
                gb = int(float(val))
                result["min_gpu_mem_gb"] = gb
                result["sku_type"] = "gpu"
                result["confidence"] = "high"
                result["source"] = f"{key} = {gb}"
                result["recommended_sku"] = f"(GPU with >= {gb} GB VRAM)"
                return result
            except (ValueError, TypeError):
                pass

    # --- 3. skuBasedEngineIds / catalog deployment properties ---
    inferred_type, inferred_source = infer_sku_type_from_properties(properties or {})
    if inferred_type:
        result["sku_type"] = inferred_type
        result["confidence"] = "high"
        result["source"] = inferred_source
        result["recommended_sku"] = "(catalog-managed engine; verify in Azure ML Studio)"
        result["gpu_arch"] = _infer_gpu_arch(engine_template, result["skus_by_type"]["gpu"])
        return result

    # --- 4. Heuristic from tags and name ---
    all_str = json.dumps(tags).lower()
    gpu_signals = [kw for kw in ["gpu", "cuda", "nvidia", "float16", "bfloat16"] if kw in all_str]
    name_lower = name.lower()

    if re.search(r"(?:multilingual|instruct|\d{1,3}b(?:-|$))", name_lower):
        gpu_signals.append("name:large_model")
    cpu_signals = []
    if any(p in name_lower for p in ["mini", "small", "tiny", "-en-"]):
        cpu_signals.append("name:small_model")

    if gpu_signals and not cpu_signals:
        result["sku_type"] = "gpu"
        result["confidence"] = "medium"
        result["source"] = f"Heuristic: {', '.join(gpu_signals)}"
        result["recommended_sku"] = "(verify in Azure ML Studio)"
    elif cpu_signals:
        result["sku_type"] = "cpu"
        result["confidence"] = "medium"
        result["source"] = f"Heuristic: {', '.join(cpu_signals)}"
        result["recommended_sku"] = "(verify in Azure ML Studio)"
    else:
        result["sku_type"] = "unknown"
        result["source"] = "No indicators - deploy via Azure ML Studio to discover"
        result["recommended_sku"] = "(unknown)"

    return result


def print_report(info: dict, include_tfvars_snippet: bool = False) -> None:
    """Print formatted report for a model."""
    icons = {"cpu": "CPU", "gpu": "GPU", "cpu+gpu": "CPU+GPU", "unknown": "???"}
    conf = {"high": "[OK]", "medium": "[WARN]", "low": "[?]"}

    print(f"{'=' * 80}")
    print(f"  Model:         {info['model']}")
    print(f"  Version:       {info['version']}")
    if info.get("model_size"):
        print(f"  Model Size:    {info['model_size']}")
    print(f"  Task:          {info['task']}")
    if info.get("engine_template"):
        print(f"  Template:      {info['engine_template']}")
    print(f"  URI:           {info['uri']}")
    print(f"  SKU Type:      {icons.get(info['sku_type'], '?')} {conf.get(info['confidence'], '')}")
    if info.get("gpu_arch") and info.get("sku_type") in ("gpu", "cpu+gpu"):
        print(f"  GPU Type:      {info['gpu_arch']}")
    print(f"  Source:        {info['source']}")
    print(f"  Recommended:   {info['recommended_sku']}")

    if info["min_gpu_mem_gb"]:
        print(f"  Min GPU VRAM:  {info['min_gpu_mem_gb']} GB")

    if info["allowed_skus"]:
        print(f"  Allowed SKUs:  ({len(info['allowed_skus'])} total)")
        if info["skus_by_type"]["cpu"]:
            print(f"    CPU: {', '.join(info['skus_by_type']['cpu'])}")
        if info["skus_by_type"]["gpu"]:
            print(f"    GPU: {', '.join(info['skus_by_type']['gpu'])}")
            # Print GPU hardware for each SKU
            for sku in info["skus_by_type"]["gpu"]:
                m = re.match(r"Standard_(NC\d+(?:s|as|ads|adis)?_[A-Za-z0-9]+)", sku)
                if m:
                    family = m.group(1)
                    for pattern, gpu_name in _SKU_GPU_NAMES.items():
                        if pattern in family:
                            print(f"         {sku} -> {gpu_name}")
                            break

    if include_tfvars_snippet:
        print()
        safe = re.sub(r"[^a-zA-Z0-9-]", "-", info["model"])[:32]
        print(f"  # terraform.tfvars:")
        print(f'  deployment_name = "{safe}"')
        print(f'  model_id        = "{info["uri"]}"')
        if info["recommended_sku"] and info["recommended_sku"].startswith("Standard_"):
            print(f'  # Auto-selected SKU: {info["recommended_sku"]}')
    print(f"{'=' * 80}")
    print()


def print_sku_map(results: list) -> None:
    """Print Terraform model_sku_map for locals.tf."""
    entries = [(r["model"], r["recommended_sku"]) for r in results
               if r["recommended_sku"] and r["recommended_sku"].startswith("Standard_")]
    if not entries:
        return

    print("=" * 80)
    print("  Auto-generated model_sku_map for locals.tf:")
    print("=" * 80)
    print()
    print("  model_sku_map = {")
    for name, sku in sorted(entries):
        print(f'    "{name}" = "{sku}"')
    print("  }")
    print()


def cmd_single(client: MLClient, model_name: str, version: str = None):
    """Look up a single model."""
    try:
        versions = list(client.models.list(name=model_name))
    except Exception as e:
        print(f"  Error listing model '{model_name}': {e}")
        return None

    if not versions:
        print(f"  Model '{model_name}' not found in registry '{REGISTRY}'")
        return None

    if version:
        target = version
    else:
        target = str(max(int(v.version) for v in versions))

    try:
        model = client.models.get(name=model_name, version=target)
    except Exception as e:
        print(f"  Error fetching {model_name} v{target}: {e}")
        return None

    tags = model.tags or {}
    properties = model.properties or {}
    return analyze_model(model_name, target, tags, properties)


def cmd_search(client: MLClient, filter_str: str, include_tfvars_snippet: bool = False):
    """Search models matching a filter."""
    print(f"  Listing models from registry '{REGISTRY}' (may take 30-60s)...")
    try:
        all_models = list(client.models.list())
    except Exception as e:
        print(f"  Error listing registry: {e}")
        return []

    seen = {}
    for m in all_models:
        if filter_str.lower() in m.name.lower():
            ver = int(m.version)
            if m.name not in seen or ver > seen[m.name][0]:
                seen[m.name] = (ver, m)

    results = []
    print(f"  Found {len(seen)} models matching '{filter_str}'\n")

    for name in sorted(seen):
        ver, _ = seen[name]
        try:
            model = client.models.get(name=name, version=str(ver))
            tags = model.tags or {}
            properties = model.properties or {}
        except Exception:
            tags = {}
            properties = {}

        info = analyze_model(name, str(ver), tags, properties)
        results.append(info)
        print_report(info, include_tfvars_snippet)

    return results


def main():
    parser = argparse.ArgumentParser(
        description="Azure ML HuggingFace Model SKU Checker (SDK v2)")
    parser.add_argument("--model", "-m",
                        help="Exact model name (e.g. alibaba-nlp-gte-large-en-v1.5)")
    parser.add_argument("--filter", "-f", default="alibaba-nlp-gte",
                        help="Filter to search models (default: alibaba-nlp-gte)")
    parser.add_argument("--version", "-v",
                        help="Specific version (default: latest)")
    parser.add_argument("--show-tfvars-snippet", action="store_true",
                        help="Include terraform.tfvars snippet in model report output")
    args = parser.parse_args()

    print()
    print("=" * 80)
    print("  Azure ML HuggingFace Model -> SKU Checker")
    print(f"  Registry: {REGISTRY}  |  SDK: azure-ai-ml v2")
    print("=" * 80)
    print()

    client = get_registry_client()
    results = []

    if args.model:
        print(f"  Looking up: {args.model}...")
        info = cmd_single(client, args.model, args.version)
        if info:
            results.append(info)
            print()
            print_report(info, args.show_tfvars_snippet)
    else:
        results = cmd_search(client, args.filter, args.show_tfvars_snippet)

    if results:
        print_sku_map(results)


if __name__ == "__main__":
    main()
