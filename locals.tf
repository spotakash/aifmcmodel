# =============================================================================
# Locals — derive all resource names from project_name
#
# Convention: <project_name><suffix>
# This eliminates per-resource name variables and keeps tfvars minimal.
# =============================================================================

locals {
  # Merge default tags with user-supplied tags
  tags = merge({
    SecurityControl = "Ignore"
    environment     = var.environment
    project         = var.project_name
  }, var.tags)

  # Azure API string for public network access
  public_network_access = var.public_network_access ? "Enabled" : "Disabled"

  # Safe prefix: ensures names always start with a letter even if
  # project_name starts with a digit (e.g. "1503ak").
  safe_prefix = can(regex("^[a-zA-Z]", var.project_name)) ? var.project_name : "p${var.project_name}"

  # --- Derived resource names ---
  resource_group_name          = var.project_name                # RG allows digits at start
  storage_account_name         = "${var.project_name}gte"        # SA allows digits at start
  key_vault_name               = "kv-${local.safe_prefix}-gte"   # 3-24, must start with letter
  log_analytics_workspace_name = "${local.safe_prefix}-gte-la"   # must start with alphanumeric
  application_insights_name    = "${local.safe_prefix}-gte-appi" # liberal naming
  container_registry_name      = "acr${local.safe_prefix}gte"    # alphanumeric only, must start with letter

  # AI Foundry workspaces — must start with letter
  ai_hub_name     = "hub-${local.safe_prefix}"
  ai_project_name = "prj-${local.safe_prefix}-gte"

  # CMK resources (separate resource group)
  cmk_resource_group_name = "${var.project_name}-cmk"
  cmk_key_vault_name      = "kv-${local.safe_prefix}-cmk"
  cmk_key_name            = "cmk-${local.safe_prefix}"
  cmk_identity_name       = "id-${local.safe_prefix}-cmk"

  # Endpoint — must start with letter
  endpoint_name = "ep-${local.safe_prefix}-gte"

  # --- Private networking resources (conditional on public_network_access = false) ---
  vnet_name        = "vnet-${local.safe_prefix}"
  bastion_name     = "bas-${local.safe_prefix}"
  bastion_pip_name = "pip-bas-${local.safe_prefix}"
  jumpbox_name     = "vm-${local.safe_prefix}-dsvm"
  jumpbox_nic_name = "nic-${local.safe_prefix}-dsvm"
  jumpbox_os_disk  = "osdisk-${local.safe_prefix}-dsvm"
  pe_hub_name      = "pe-${local.safe_prefix}-hub"

  # Subnet CIDRs — derived from VNet address space (/22 = 1024 IPs)
  # Azure reserves 5 IPs per subnet (first 4 + last 1).
  # AzureBastionSubnet: /26 (64 IPs, 59 usable) — Azure-mandated minimum
  # PrivateEndpoint:    /27 (32 IPs, 27 usable) — room for multiple PE NICs
  # Jumpbox:            /29 (8 IPs, 3 usable)   — smallest usable subnet for 1 VM
  # Spare:              /24 (256 IPs, 251 usable) — reserved for future workloads
  #
  # Layout (10.0.0.0/22 example):
  #   10.0.0.0/26   — AzureBastionSubnet  (0-63)
  #   10.0.0.64/27  — PrivateEndpoint     (64-95)
  #   10.0.0.96/29  — Jumpbox             (96-103)
  #   10.0.1.0/24   — Spare               (256-511)
  bastion_subnet_cidr = cidrsubnet(var.vnet_address_space, 4, 0)
  pe_subnet_cidr      = cidrsubnet(var.vnet_address_space, 5, 2)
  jumpbox_subnet_cidr = cidrsubnet(var.vnet_address_space, 7, 12)
  spare_subnet_cidr   = cidrsubnet(var.vnet_address_space, 2, 1)

  # --- Model-to-SKU auto-mapping ---
  # Some HuggingFace models require GPU; others work on CPU.
  # This map overrides deployment_instance_type based on model_id.
  model_sku_map = {
    "alibaba-nlp-gte-large-en-v1.5"     = "Standard_DS5_v2"          # CPU OK
    "alibaba-nlp-gte-large-en-v1"       = "Standard_DS5_v2"          # CPU OK
    "alibaba-nlp-gte-multilingual-base" = "Standard_NC4as_T4_v3"     # GPU required
    "alibaba-nlp-gte-Qwen2-7B-instruct" = "Standard_NC24ads_A100_v4" # GPU required
  }

  # Extract model short name from model_id URI
  # e.g. "azureml://registries/HuggingFace/models/alibaba-nlp-gte-large-en-v1.5/versions/11"
  #   -> "alibaba-nlp-gte-large-en-v1.5"
  model_short_name = try(regex("/models/([^/]+)/versions/", var.model_id)[0], "unknown")

  # Auto-select SKU: use map if model is known, otherwise fall back to var
  resolved_instance_type = lookup(local.model_sku_map, local.model_short_name, var.deployment_instance_type)
}
