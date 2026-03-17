# Model SKU Checker Scripts

Scripts to check which Azure VM SKU (CPU vs GPU) is required for a HuggingFace model before deploying via Terraform.

> **Note:** This tool currently only supports models from the **HuggingFace** provider in the [Azure AI Foundry Model Catalog](https://ai.azure.com/explore/models). Other catalog providers (Meta, Microsoft, Mistral, etc.) are not supported at this time.

## Prerequisites

- Azure CLI authenticated (`az login`) or any Azure identity (managed identity, service principal)
- Python 3.8+
- Python packages:
  ```bash
  pip install azure-ai-ml azure-identity
  ```
- Azure Managed Online Endpoint SKU list https://learn.microsoft.com/en-us/azure/machine-learning/reference-managed-online-endpoints-vm-sku-list?view=azureml-api-2

## Usage

### Check a specific model

```bash
python check_model_sku.py --model alibaba-nlp-gte-large-en-v1.5
python check_model_sku.py --model alibaba-nlp-gte-multilingual-base
```

### Search all models matching a filter

```bash
# All Alibaba GTE models
python check_model_sku.py --filter alibaba-nlp-gte

# All sentence-transformers
python check_model_sku.py --filter sentence-transformers

# All BAAI BGE models
python check_model_sku.py --filter BAAI-bge
```

### Check a specific version

```bash
python check_model_sku.py --model alibaba-nlp-gte-large-en-v1.5 --version 11
```

## How It Works

The script queries the **HuggingFace registry** in Azure AI Foundry Model Catalog (`azureml://registries/HuggingFace`) and reads model metadata — not hardcoded lists:

1. **High confidence** — reads `inference_compute_allow_list` tag from the model registry.
   This tag contains the exact SKU list Azure has validated for that model.
2. **High confidence** — reads `min_inference_gpu_mem_in_gb` tag to know GPU is required.
3. **High confidence** — reads `catalog.skuBasedEngineIds` (deployment engine template mapping).
4. **Medium confidence** — heuristic from model name patterns (used only when source metadata is missing).
5. **Low confidence** — no indicators found; recommends checking Azure ML Studio.

## Catalog Templates (`tei-gpu-extra-small`, `tei-cpu-sm`)

When available, the script prints a `Template:` line extracted from `catalog.skuBasedEngineIds`.

- `tei-gpu-extra-small`
  - A Text Embeddings Inference (TEI) GPU-oriented engine template.
  - Indicates GPU-backed deployment path in Azure ML managed online endpoints.
- `tei-cpu-sm`
  - A TEI CPU-oriented small engine template.
  - Indicates CPU-backed deployment path.

Important notes:
- These template values come from **model catalog source metadata**, not hardcoded script conditions.
- Some models expose both CPU and GPU templates in `skuBasedEngineIds`; the script reports `SKU Type: CPU+GPU` in that case.
- Template names are engine profiles, not direct VM size names (`Standard_*`). Final VM size depends on region, quota, and capacity.

## Example Output

```
────────────────────────────────────────────────────────────────────────────────
  Model:         alibaba-nlp-gte-large-en-v1.5
  Version:       11
  Task:          embeddings
  URI:           azureml://registries/HuggingFace/models/alibaba-nlp-gte-large-en-v1.5/versions/11
  SKU Type:      CPU [OK]
  Source:        inference_compute_allow_list (5 SKUs)
  Recommended:   Standard_DS3_v2
  Allowed SKUs:  (5 total)
    CPU: Standard_DS3_v2, Standard_DS4_v2, Standard_DS5_v2, Standard_D13_v2, Standard_D14_v2

  # terraform.tfvars:
  deployment_name = "alibaba-nlp-gte-large-en-v1-5"
  model_id        = "azureml://registries/HuggingFace/models/alibaba-nlp-gte-large-en-v1.5/versions/11"
  # Auto-selected SKU: Standard_DS3_v2
────────────────────────────────────────────────────────────────────────────────
```

## Auto-Generated Terraform Map

When scanning multiple models, the script outputs a ready-to-paste `model_sku_map` for `locals.tf`:

```
  model_sku_map = {
    "alibaba-nlp-gte-large-en-v1.5"    = "Standard_DS3_v2"
    "alibaba-nlp-gte-multilingual-base" = "Standard_NC4as_T4_v3"
  }
```

Copy this into `locals.tf` to enable automatic SKU selection when switching models in `terraform.tfvars`.

## Integration with Terraform

The `locals.tf` in the parent directory reads `model_id`, extracts the model name, and looks it up in `model_sku_map`. If found, the correct SKU is used automatically. If not found, it falls back to `var.deployment_instance_type`.

Workflow:
1. Run this script to check your model
2. Copy the `model_sku_map` entry into `locals.tf` (if not already there)
3. Set `model_id` and `deployment_name` in `terraform.tfvars`
4. `terraform apply` — SKU is auto-selected
