# Azure AI Foundry + HuggingFace GTE Embedding Model — Terraform Deployment

This Terraform configuration reverse-engineers and codifies the existing Azure infrastructure for deploying a self-hosted **HuggingFace GTE embedding model** (`alibaba-nlp-gte-large-en-v1.5`) via Azure AI Foundry.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                    Resource Group                            │
│                                                              │
│  ┌─────────────┐  ┌──────────┐  ┌─────────────────────────┐ │
│  │ Storage Acct │  │ Key Vault│  │ Log Analytics + AppIns  │ │
│  └──────┬──────┘  └────┬─────┘  └────────────┬────────────┘ │
│         │              │                      │              │
│  ┌──────┴──────────────┴──────────────────────┴───────────┐  │
│  │            AI Foundry Hub (kind=Hub)                    │  │
│  │  ┌───────────────────────────────────────────────────┐  │  │
│  │  │        AI Foundry Project (kind=Project)          │  │  │
│  │  │  ┌─────────────────────────────────────────────┐  │  │  │
│  │  │  │   Managed Online Endpoint                   │  │  │  │
│  │  │  │   └─ Deployment: GTE-large-en-v1.5 (HF)    │  │  │  │
│  │  │  └─────────────────────────────────────────────┘  │  │  │
│  │  └───────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌────────────────────┐  ┌────────────┐  ┌───────────────┐  │
│  │ ML Workspace (Std) │  │    ACR     │  │  AI Services  │  │
│  │ └─ Compute (opt.)  │  └────────────┘  └───────────────┘  │
│  └────────────────────┘                                      │
└──────────────────────────────────────────────────────────────┘
```

## Prerequisites

- Terraform >= 1.6
- Azure CLI authenticated (`az login`)
- Sufficient Azure quota for `Standard_DS5_v2` in target region

## Provider Strategy

| Resource | Provider | Reason |
|---|---|---|
| Resource Group, Storage, Key Vault, ACR, Log Analytics, App Insights | `azurerm ~> 4.0` | Fully supported, stable |
| Cognitive Services (AI Services) | `azurerm` | Supported via `azurerm_cognitive_account` |
| Standard ML Workspace + Compute | `azurerm` | Supported via `azurerm_machine_learning_workspace` |
| AI Foundry Hub (kind=Hub) | `azapi ~> 2.0` | Requires `workspaceHubConfig` not in azurerm |
| AI Foundry Project (kind=Project) | `azapi` | Requires `hubResourceId` not in azurerm |
| Online Endpoint + Deployment | `azapi` | HuggingFace registry model + traffic routing |
| Sleep timer | `time ~> 0.11` | Wait for project services to initialize |

## Naming Convention

All resource names are derived from a single `project_name` variable via `locals.tf`:

| Resource | Pattern | Example (`project_name = "akgte15"`) |
|---|---|---|
| Resource Group | `<project_name>` | `akgte15` |
| Storage Account | `<project_name>gte` | `akgte15gte` |
| Key Vault | `kv-<safe_prefix>-gte` | `kv-akgte15-gte` |
| Container Registry | `acr<safe_prefix>gte` | `acrakgte15gte` |
| AI Services | `ai-<safe_prefix>` | `ai-akgte15` |
| AI Hub | `hub-<safe_prefix>` | `hub-akgte15` |
| AI Project | `prj-<safe_prefix>-gte` | `prj-akgte15-gte` |
| ML Workspace | `ml-<safe_prefix>-gte` | `ml-akgte15-gte` |
| Endpoint | `ep-<safe_prefix>-gte` | `ep-akgte15-gte` |

> **Note:** If `project_name` starts with a digit (e.g. `1503ak`), a `p` prefix is auto-added (`safe_prefix = "p1503ak"`) to satisfy Azure naming rules that require names to start with a letter.

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Terraform and provider version constraints |
| `providers.tf` | Provider configuration (KV recovery, RG force delete) |
| `variables.tf` | All input variables with validation |
| `terraform.tfvars` | Minimal config — only `project_name` + deployment params |
| `locals.tf` | All derived resource names + safe prefix logic |
| `main.tf` | Resource group + data sources |
| `storage.tf` | Storage account with ML CORS rules |
| `keyvault.tf` | Key Vault with deployer access policy |
| `monitoring.tf` | Log Analytics + Application Insights |
| `acr.tf` | Azure Container Registry |
| `cognitive.tf` | Cognitive Services (AI Services) |
| `ml_hub.tf` | AI Foundry Hub workspace |
| `ml_project.tf` | AI Foundry Project workspace (inherits from Hub) |
| `ml_workspace.tf` | Standard ML workspace + optional compute |
| `endpoint.tf` | Online endpoint + HuggingFace model deployment |
| `outputs.tf` | Key resource outputs |

## Usage

```bash
# Initialize
terraform init

# Review plan
terraform plan -out=tfplan

# Deploy (model deployment takes ~10-15 min)
terraform apply tfplan

# Destroy Plan
terraform plan -destroy -out=main.destroy.tfplan

# Apply Destroy
terraform apply main.destroy.tfplan

# Destroy is fully automated — the AI Project has a destroy-time provisioner
# that cleans up child online endpoints before project deletion.
# Manual targeted destroy (only if automation fails):
terraform destroy -target=azapi_resource.model_deployment -auto-approve
terraform destroy -target=azapi_resource.online_endpoint -auto-approve
terraform destroy -auto-approve
```

> **WSL / Windows Note:** All `local-exec` provisioners use single-line commands to avoid
> CRLF (`\r\n`) issues when the workspace lives on `/mnt/c/` (Windows filesystem via WSL).
> Do **not** use multi-line heredocs (`<<-EOT`) in provisioner commands in this project.

## Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `project_name` | Yes | — | 3-12 lowercase alphanumeric chars |
| `deployment_name` | Yes | — | Model deployment name |
| `model_id` | Yes | — | Azure ML registry model URI |
| `location` | No | `australiaeast` | Azure region |
| `environment` | No | `dev` | Environment tag |
| `public_network_access` | No | `true` | Enable/disable public access on all resources |
| `create_compute_instance` | No | `false` | Create optional compute instance |
| `deployment_instance_type` | No | `Standard_DS5_v2` | VM size for model serving |
| `deployment_instance_count` | No | `1` | Number of serving instances |

## Key Design Decisions

### Resources Excluded (auto-managed by Azure)

- **Key Vault access policies** — ML workspaces auto-register their managed identities
- **Key Vault secrets** — auto-created for endpoint keys and datastore credentials
- **ML workspace environments** — built-in AzureML curated environments
- **ML workspace datastores** — auto-provisioned (`workspaceblobstore`, `workspaceartifactstore`, etc.)
- **Log Analytics saved searches & tables** — default platform tables
- **Storage containers & file shares** — auto-created by ML workspaces

### AI Foundry Project Properties

Projects inherit `keyVault`, `storageAccount`, `containerRegistry`, and `applicationInsights` from the parent Hub via `hubResourceId`. These must **not** be set on project creation.

### Deployment Timing

A 120-second `time_sleep` is inserted between project creation and endpoint creation to allow Azure to fully initialize the managed endpoints service. The model deployment itself takes ~10-15 minutes.

### Model-to-SKU Auto-Mapping

Some HuggingFace models require GPU VMs; others work on CPU. The `locals.tf` contains a `model_sku_map` that **auto-selects the correct VM SKU** based on the `model_id`:

| Model | SKU Type | Auto-Selected VM | Params |
|---|---|---|---|
| `alibaba-nlp-gte-large-en-v1.5` | CPU | `Standard_DS5_v2` | 434M |
| `alibaba-nlp-gte-large-en-v1` | CPU | `Standard_DS5_v2` | 434M |
| `alibaba-nlp-gte-multilingual-base` | **GPU** | `Standard_NC4as_T4_v3` | 305M |
| `alibaba-nlp-gte-Qwen2-7B-instruct` | **GPU** | `Standard_NC24ads_A100_v4` | 7B |

**How it works:** The model short name is extracted from the `model_id` URI and looked up in the map. If the model isn't in the map, it falls back to `var.deployment_instance_type` (default: `Standard_DS5_v2`).

To add a new model, add an entry to `model_sku_map` in `locals.tf`.

> **Important:** If you deploy a GPU-required model on a CPU SKU, Azure returns `ModelDeploymentSettingsSkuBasedEngineNotFound`. The auto-mapping prevents this.

### Checking Model SKU Before Deploying

Use the script in `scripts/` to query Azure ML Registry **before** deploying:

```bash
# Check a specific model
python scripts/check_model_sku.py --model alibaba-nlp-gte-large-en-v1.5

# Scan all GTE models and auto-generate locals.tf map
python scripts/check_model_sku.py --filter alibaba-nlp-gte
```

See [scripts/README.md](scripts/README.md) for full usage.

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `VaultNameNotValid` | Name starts with digit | Use `project_name` starting with a letter, or `safe_prefix` auto-fixes |
| `Project shouldn't have its own Key Vault` | KV/Storage/ACR set on project | Already fixed — project inherits from Hub |
| `ScoringTimeoutMs must be between 50 and 180000` | `requestTimeout = PT0S` | Already fixed — set to `PT90S` |
| `InternalServerError` on endpoint create | Project services not initialized | 120s sleep between project and endpoint |
| `Missing Resource Identity After Update` | azapi loses LRO tracking | 60m timeout on deployment; re-run apply |
| KV `Forbidden` / secrets access denied | Workspace identity lacks KV access | Azure auto-creates policies; wait and retry |
| `already exists` on KV access policy | Azure auto-created it first | No explicit policies — Azure manages them |
| `SkuBasedEngineNotFound: Cpu` | GPU model on CPU SKU | Auto-mapped in `locals.tf`; or set GPU SKU in tfvars |
| `Soft-deleted workspace exists` | Previous workspace in soft-delete | Auto-purged by `terraform_data` resources with 30s wait for Azure to complete purge |
| `Soft-deleted cognitive account` | Previous AI Services in soft-delete | Auto-purged by `terraform_data.purge_soft_deleted_cognitive` |
| `DeploymentName must be 3-32 chars` | Name too long | Shorten `deployment_name` in tfvars (validated at plan time) |
| `CannotDeleteResource: nested resources` | Endpoint exists under project | Auto-handled — destroy-time provisioner on `ai_project` cleans up endpoints before deletion |

## Customization

Edit `terraform.tfvars` to change:
- `project_name` — all resource names derive from this
- Model URI — swap to any HuggingFace model from Azure ML registry
- `deployment_instance_type` — VM size for model serving
- `public_network_access` — toggle all resources public/private
- `create_compute_instance` — enable optional dev compute
