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
  cognitive_account_name       = "ai-${local.safe_prefix}"       # must start with letter

  # ML workspaces — must start with letter
  ai_hub_name       = "hub-${local.safe_prefix}"
  ai_project_name   = "prj-${local.safe_prefix}-gte"
  ml_workspace_name = "ml-${local.safe_prefix}-gte"

  # Endpoint & Compute — must start with letter
  endpoint_name         = "ep-${local.safe_prefix}-gte"
  compute_instance_name = "ci-${local.safe_prefix}"

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
