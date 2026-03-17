# Copilot Instructions — Azure AI Foundry HuggingFace Model Deployment

## Project Overview

This is a **Terraform IaC project** that deploys a self-hosted HuggingFace GTE embedding model via Azure AI Foundry. The infrastructure uses `azurerm ~> 4.0`, `azapi ~> 2.0`, and `time ~> 0.11` providers.

## Architecture

```
Resource Group
 ├── Storage Account (shared by all ML workspaces)
 ├── Key Vault (shared, deployer access policy)
 ├── Log Analytics + Application Insights
 ├── Container Registry
 ├── Cognitive Services (AI Services)
 ├── AI Foundry Hub (azurerm_ai_foundry)
 │    └── AI Foundry Project (azurerm_ai_foundry_project)
 │         └── Managed Online Endpoint (azapi)
 │              └── Model Deployment (HuggingFace registry, azapi)
```

## File Layout Convention

| File | Purpose |
|---|---|
| `versions.tf` | Terraform + provider version constraints only |
| `providers.tf` | Provider configuration blocks only |
| `variables.tf` | All input variables with validation rules |
| `terraform.tfvars` | Minimal config — `project_name` + deployment params |
| `locals.tf` | All derived resource names + safe prefix logic + model SKU map |
| `main.tf` | Resource group + data sources |
| `storage.tf` | Storage account |
| `keyvault.tf` | Key Vault |
| `monitoring.tf` | Log Analytics + Application Insights |
| `acr.tf` | Container Registry |
| `cognitive.tf` | Cognitive Services |
| `ai_hub.tf` | AI Foundry Hub (azurerm_ai_foundry) |
| `ai_project.tf` | AI Foundry Project (azurerm_ai_foundry_project) |
| `endpoint.tf` | Online endpoint + model deployment (azapi) |
| `outputs.tf` | All outputs |

**Never combine resources from different domains into a single file.** Each `.tf` file owns one logical resource group.

## Naming Convention

All resource names are derived from `project_name` via `locals.tf`. Never hardcode resource names.

- `safe_prefix` auto-adds `p` prefix if `project_name` starts with a digit
- Pattern examples: `kv-<safe_prefix>-gte`, `hub-<safe_prefix>`, `ep-<safe_prefix>-gte`
- To add a new resource, add a `local.<resource>_name` in `locals.tf` and reference it

## Provider Selection Rules

1. **azurerm** — Use for stable, fully-supported resources (RG, Storage, KV, ACR, App Insights, Cognitive Services, AI Foundry Hub, AI Foundry Project)
2. **azapi** — Use only for resources without native azurerm support: online endpoints and model deployments (HuggingFace registry + traffic routing)
3. **time** — Only for `time_sleep` between project creation and endpoint creation

## Key Coding Conventions

### Terraform Style
- Use `=` alignment within resource blocks for readability
- Section headers with `# ====` comment blocks
- Every resource gets `tags = local.tags` (except azapi child resources that inherit)
- Variables must have `description`, `type`, and `default` (where sensible)
- Use `validation` blocks on variables with strict constraints (e.g. `project_name` regex)

### azapi Resources
- Always set `schema_validation_enabled = false` and `ignore_missing_property = true`
- Use native HCL maps for `body` (not `jsonencode`) — azapi v2 supports this
- Set generous timeouts: `create = "10m"` for endpoints, `create = "60m"` for model deployments
- Use `lifecycle { ignore_changes = [...] }` for properties Azure modifies (e.g. `traffic`, `associatedWorkspaces`)

### Model-to-SKU Mapping
- `locals.tf` contains `model_sku_map` that auto-selects the correct VM SKU per model
- The model short name is extracted from the `model_id` URI via regex
- If the model isn't mapped, it falls back to `var.deployment_instance_type`
- When adding a new HuggingFace model, add an entry to `model_sku_map`

### Soft-Delete Handling
- Use `terraform_data` with `provisioner "local-exec"` to purge soft-deleted resources before recreation
- Applied to: AI Foundry Hub, AI Foundry Project, Cognitive Account
- Pattern: `az rest --method DELETE --url '...?forceToPurge=true' 2>/dev/null || true; sleep 30`
- Add `sleep 30` after purge to let Azure complete the async purge before workspace creation

### Destroy-Time Cleanup
- AI Foundry Project has a destroy-time `local-exec` provisioner that deletes child online endpoints before project deletion
- This prevents the `CannotDeleteResource: nested resources` 409 error
- Pattern: single-line `bash -c '...'` command that lists and deletes endpoints via Azure REST API

### WSL / CRLF Safety
- **Never** use multi-line heredocs (`<<-EOT`) in `local-exec` provisioner commands
- Files on `/mnt/c/` have Windows CRLF line endings; heredoc newlines include `\r` which breaks shell parsing
- Always write provisioner commands as single-line strings (use `;` to chain commands)

### AI Foundry Project Rules
- Projects inherit `keyVault`, `storageAccount`, `containerRegistry`, `applicationInsights` from Hub
- **Never** set these properties on the project — only set `ai_services_hub_id`
- A 120s `time_sleep` is required between project creation and endpoint creation

### Dependencies
- Explicit `depends_on` for ordering: project → sleep → endpoint → deployment
- Data sources like `azurerm_client_config.current` go in `main.tf`

## Variable Management
- Keep `terraform.tfvars` minimal — only `project_name` and deployment-specific values
- All derived names belong in `locals.tf`, not as separate variables
- Use `bool` variables with sensible defaults for feature flags (`public_network_access`)

## Security Rules
- No secrets in code or tfvars
- `min_tls_version = "TLS1_2"` on storage accounts
- `allow_nested_items_to_be_public = false` on storage
- `local_auth_enabled = false` on cognitive accounts
- `purge_protection_enabled = false` on Key Vault (dev environment)
- Let Azure auto-manage KV access policies for ML workspace identities

## Outputs
- Export `id` and key attributes (name, URI, login_server, connection_string) for each resource
- Mark sensitive outputs with `sensitive = true`
- Group outputs by resource with comment headers

## Common Commands
```bash
terraform init
terraform plan -out=tfplan
terraform apply tfplan
terraform plan -destroy -out=main.destroy.tfplan
terraform apply main.destroy.tfplan
```

## When Modifying This Project
1. New resource → create a dedicated `.tf` file, add name to `locals.tf`, add output to `outputs.tf`
2. New model → add entry to `model_sku_map` in `locals.tf`
3. New variable → add to `variables.tf` with description + validation, update `terraform.tfvars` if user-facing
4. Provider upgrade → update `versions.tf` constraints, check azapi body syntax compatibility
