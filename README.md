# Azure AI Foundry + Custom Open Source Model from AI Foundry Model Catalog — Terraform Deployment

This Terraform configuration deploys a self-hosted **HuggingFace GTE embedding model** (`alibaba-nlp-gte-large-en-v1.5`) via Azure AI Foundry with CMK encryption and AllowOnlyApprovedOutbound managed network isolation.

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  CMK Resource Group (<project>-cmk)                          │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Key Vault (purge-protected, RBAC)                      │  │
│  │  └─ RSA 2048 Key (CMK for AI Hub encryption)           │  │
│  │ User-Assigned Identity (Crypto User + Reader on KV)    │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────┐
│  Main Resource Group (<project>)                             │
│                                                              │
│  ┌─────────────┐  ┌──────────┐  ┌─────────────────────────┐ │
│  │ Storage Acct │  │ Key Vault│  │ Log Analytics + AppIns  │ │
│  └──────┬──────┘  └────┬─────┘  └────────────┬────────────┘ │
│         │              │                      │              │
│  ┌──────┴──────────────┴──────────────────────┴───────────┐  │
│  │  AI Foundry Hub (azapi, CMK-encrypted)                 │  │
│  │                                                        │  │
│  │  ┌ AllowOnlyApprovedOutbound Managed VNet ───────────┐ │  │
│  │  │                                                    │ │  │
│  │  │  Private Link Endpoints (auto-created, require     │ │  │
│  │  │  auto-approval via Network Connection Approver):   │ │  │
│  │  │   ├─ PE → Storage Account                         │ │  │
│  │  │   ├─ PE → Key Vault                               │ │  │
│  │  │   ├─ PE → Container Registry (Premium required)   │ │  │
│  │  │   └─ PE → Application Insights                    │ │  │
│  │  │                                                    │ │  │
│  │  │  Azure Firewall (Standard, auto-created):          │ │  │
│  │  │   FQDN Outbound Rules:                            │ │  │
│  │  │   ├─ docker.io  *.docker.io  *.docker.com         │ │  │
│  │  │   ├─ production.cloudflare.docker.com              │ │  │
│  │  │   ├─ cdn.auth0.com                                │ │  │
│  │  │   ├─ huggingface.co  *.huggingface.co             │ │  │
│  │  │   ├─ cdn-lfs.huggingface.co                       │ │  │
│  │  │   └─ xethub.hf.co  *.xethub.hf.co                │ │  │
│  │  │                                                    │ │  │
│  │  │  Auto-allowed (built-in rules):                    │ │  │
│  │  │   AAD, ARM, Azure ML, MCR, Azure Front Door       │ │  │
│  │  └────────────────────────────────────────────────────┘ │  │
│  │                                                        │  │
│  │  ┌───────────────────────────────────────────────────┐ │  │
│  │  │  AI Foundry Project (azurerm_ai_foundry_project)  │ │  │
│  │  │  ┌─────────────────────────────────────────────┐  │ │  │
│  │  │  │  Managed Online Endpoint (azapi)             │  │ │  │
│  │  │  │  └─ Model Deployment (azapi, HuggingFace)    │  │ │  │
│  │  │  └─────────────────────────────────────────────┘  │ │  │
│  │  └───────────────────────────────────────────────────┘ │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌──────────────┐                                            │
│  │  ACR (Premium)│                                           │
│  └──────────────┘                                            │
└──────────────────────────────────────────────────────────────┘

Microsoft-Managed Subscription (enableServiceSideCMKEncryption = true):
  Cosmos DB, AI Search, Storage Account for workspace metadata
  are created and managed entirely by Microsoft in their own
  subscription — not visible in customer's resource groups.
```

## Prerequisites

- Terraform >= 1.6
- Azure CLI authenticated (`az login`)
- Sufficient Azure quota for `Standard_DS5_v2` in target region

## Provider Strategy

| Resource | Provider | Reason |
|---|---|---|
| Resource Group, Storage, Key Vault, ACR, Log Analytics, App Insights | `azurerm ~> 4.0` | Fully supported, stable |
| CMK Key Vault, Key, User-Assigned Identity, RBAC | `azurerm` | CMK encryption for AI Hub |
| AI Foundry Hub | `azapi ~> 2.0` | CMK + managed network + `kind=Hub` via ARM API |
| AI Foundry Project | `azurerm` | Supported via `azurerm_ai_foundry_project` |
| FQDN Outbound Rules | `azurerm` | Managed network egress rules via `azurerm_machine_learning_workspace_network_outbound_rule_fqdn` |
| Managed Network Provisioning | `azapi` | `provisionManagedNetwork` action (LRO) |
| Online Endpoint + Deployment | `azapi ~> 2.0` | HuggingFace registry model + traffic routing (no azurerm support) |
| Sleep timer | `time ~> 0.11` | Wait for project services to initialize |

## Naming Convention

All resource names are derived from a single `project_name` variable via `locals.tf`:

| Resource | Pattern | Example (`project_name = "akgte15"`) |
|---|---|---|
| Resource Group | `<project_name>` | `akgte15` |
| Storage Account | `<project_name>gte` | `akgte15gte` |
| Key Vault | `kv-<safe_prefix>-gte` | `kv-akgte15-gte` |
| Container Registry | `acr<safe_prefix>gte` | `acrakgte15gte` |
| AI Hub | `hub-<safe_prefix>` | `hub-akgte15` |
| AI Project | `prj-<safe_prefix>-gte` | `prj-akgte15-gte` |
| Endpoint | `ep-<safe_prefix>-gte` | `ep-akgte15-gte` |
| CMK Resource Group | `<project_name>-cmk` | `akgte15-cmk` |
| CMK Key Vault | `kv-<safe_prefix>-cmk` | `kv-akgte15-cmk` |
| CMK Key | `cmk-<safe_prefix>` | `cmk-akgte15` |
| CMK Identity | `id-<safe_prefix>-cmk` | `id-akgte15-cmk` |

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
| `monitoring.tf` | Log Analytics + Application Insights + Diagnostic Settings |
| `acr.tf` | Azure Container Registry |
| `cmk.tf` | CMK Key Vault + RSA Key + User-Assigned Identity + RBAC (separate RG) |
| `ai_hub.tf` | AI Foundry Hub (azapi, CMK-encrypted, managed network + FQDN rules) |
| `ai_project.tf` | AI Foundry Project (azurerm_ai_foundry_project) |
| `endpoint.tf` | Online endpoint + model deployment from AI Foundry Model Catalog (azapi) |
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

### AI Foundry Hub (azapi) & Project (azurerm)

The Hub uses the `azapi` provider (`Microsoft.MachineLearningServices/workspaces@2025-01-01-preview` with `kind=Hub`) for full ARM API control over CMK encryption, managed network isolation, and FQDN outbound rules. The Project (`azurerm_ai_foundry_project`) uses the native azurerm provider. Only the online endpoint and model deployment use azapi (no azurerm equivalent exists for managed online endpoints with model catalog registry deployments).

### Managed Network & FQDN Outbound Rules

The Hub uses `AllowOnlyApprovedOutbound` managed network isolation. All egress is blocked unless explicitly allowed via FQDN outbound rules. The following domains are required for HuggingFace model deployments:

| Rule | FQDN | Purpose |
|---|---|---|
| Docker Hub | `docker.io`, `*.docker.io`, `*.docker.com` | Container image pull |
| Cloudflare CDN | `production.cloudflare.docker.com` | Docker image layer CDN |
| Auth0 | `cdn.auth0.com` | Docker Hub authentication |
| HuggingFace | `huggingface.co`, `*.huggingface.co` | Model config + tokenizer downloads |
| HuggingFace LFS | `cdn-lfs.huggingface.co` | Large file storage (legacy) |
| HuggingFace Xet | `xethub.hf.co`, `*.xethub.hf.co` | Model weights (safetensors, ONNX) via Xet storage |

FQDN rules trigger Azure Firewall (Standard SKU) creation. The managed network is explicitly provisioned via `azapi_resource_action` before endpoints are created.

### RBAC & Access Policies

All role assignments and access policies required by this deployment:

#### RBAC Role Assignments

| Identity | Role | Scope | Purpose | File |
|---|---|---|---|---|
| **Deployer** (current user) | Key Vault Administrator | CMK Key Vault | Create/manage the CMK encryption key | `cmk.tf` |
| **CMK UAI** (User-Assigned Identity) | Key Vault Crypto User | CMK Key Vault | Wrap/unwrap the CMK key for Hub encryption | `cmk.tf` |
| **CMK UAI** | Reader | CMK Key Vault | `vaults/read` — required to discover the KV resource | `cmk.tf` |
| **Hub System Identity** | Azure AI Enterprise Network Connection Approver | Main Resource Group | Auto-approve Private Link endpoints during managed network provisioning | `ai_hub.tf` |
| **CMK UAI** | Azure AI Enterprise Network Connection Approver | Main Resource Group | Same PE approval — Azure uses primary UAI for network ops | `ai_hub.tf` |
| **CMK UAI** | Contributor | Main Resource Group | Resource-level read/write (e.g. `registries/read`) needed for PE approval | `ai_hub.tf` |

> **Why both System + UAI get Network Connection Approver?** When `primaryUserAssignedIdentity` is set, Azure uses that identity for workspace operations. However, some internal operations still use the System identity. Both need PE approval permissions.

> **RBAC propagation:** Azure RBAC is eventually consistent. A 60s wait (`time_sleep.wait_for_cmk_rbac`) is added after CMK role assignments, and a 120s wait (`time_sleep.wait_for_hub_rbac`) after Hub role assignments, before dependent resources are created.

#### Key Vault Access Policies (Operational KV)

The operational Key Vault (`keyvault.tf`) uses access policies (not RBAC):

| Identity | Key Permissions | Secret Permissions | Certificate Permissions | Purpose |
|---|---|---|---|---|
| **Deployer** (current user) | Get, List, Create, Delete, Update, Purge, Recover | Get, List, Set, Delete, Purge, Recover | Get, List, Create, Delete, Update, Purge, Recover | Full deployer access |
| **Hub System Identity** | Get, List, Create, Delete, Update, Recover, WrapKey, UnwrapKey | Get, List, Set, Delete, Recover | Get, List, Create, Delete, Update, Recover | Workspace operations (managed network blocks auto-creation) |
| **CMK UAI** | Get, List, Create, Delete, Update, Recover, WrapKey, UnwrapKey | Get, List, Set, Delete, Recover | Get, List, Create, Delete, Update, Recover | Primary identity for workspace operations |

> **Why explicit KV access policies?** With `AllowOnlyApprovedOutbound` managed network, Azure ML cannot auto-create its own KV access policies. These must be granted explicitly after Hub creation.

### Customer-Managed Key (CMK) Encryption

The AI Foundry Hub is encrypted with a customer-managed RSA 2048 key stored in a **separate Key Vault** (`cmk.tf`) in its own resource group (`<project>-cmk`). This requires:

- **CMK Key Vault**: Purge-protected, RBAC-enabled (required by Azure for CMK workspaces)
- **User-Assigned Identity**: Assigned `Key Vault Crypto User` + `Reader` roles on the CMK vault
- **60s RBAC propagation wait**: Azure RBAC is eventually consistent; the Hub creation waits for roles to propagate
- **Two Key Vaults**: The operational KV (`keyvault.tf`) stores Hub secrets/credentials; the CMK KV (`cmk.tf`) holds only the encryption key. These serve different purposes and use different auth models (access policies vs RBAC)

> **Note:** With `enableServiceSideCMKEncryption = true`, the workspace's backing Cosmos DB, AI Search, and Storage Account are created and managed entirely by Microsoft in their own subscription — they do not appear in any customer resource group. This is the server-side CMK encryption model. Without this flag, Azure creates these in a customer-visible managed resource group (`azureml-rg-hub-<name>-<guid>`).

### Monitoring & Diagnostics

Platform diagnostics are configured for Key Vault (audit logs), Storage Account (transaction metrics + blob read/write/delete logs), with all data flowing to the shared Log Analytics workspace. Model deployment inference telemetry flows to Application Insights (`appInsightsEnabled = true`).

### AI Foundry Project Properties

Projects inherit `keyVault`, `storageAccount`, `containerRegistry`, and `applicationInsights` from the parent Hub via `ai_services_hub_id`. These must **not** be set on project creation.

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
| `DeploymentName must be 3-32 chars` | Name too long | Shorten `deployment_name` in tfvars (validated at plan time) |
| `CannotDeleteResource: nested resources` | Endpoint exists under project | Auto-handled — destroy-time provisioner on `ai_project` waits 90s for Azure cleanup after endpoint deletion |
| `CMK keyvault purge protection` | CMK KV missing purge protection | CMK Key Vault must have `purge_protection_enabled = true` (Azure-enforced) |
| `User assigned identity doesn't have enough permissions` | CMK identity lacks `vaults/read` | Identity needs both `Key Vault Crypto User` + `Reader` roles on CMK vault |
| `soft_delete_retention_days cannot be modified` | Existing KV retention mismatch | Must destroy and recreate the KV — `soft_delete_retention_days` is immutable |
| `User container has crashed` on model deployment | Model weight download blocked by managed network | Add FQDN rules for `huggingface.co`, `*.huggingface.co`, `xethub.hf.co`, `*.xethub.hf.co` |
| `Provider produced inconsistent result` on FQDN rule | azurerm provider bug — Azure creates rule but read-back is empty | Re-run `terraform apply` — rules will be recreated |
| `InternalServerError` on Hub update | Azure rejects in-place changes to `hbiWorkspace` or `publicNetworkAccess` | Added to `lifecycle { ignore_changes }` — Terraform won't attempt the update |

## Customization

Edit `terraform.tfvars` to change:
- `project_name` — all resource names derive from this
- Model URI — swap to any open source model from AI Foundry Model Catalog
- `deployment_instance_type` — VM size for model serving
- `public_network_access` — toggle all resources public/private
