# =============================================================================
# Key Vault — shared by all ML workspaces
# =============================================================================

resource "azurerm_key_vault" "ml" {
  name                       = local.key_vault_name
  resource_group_name        = azurerm_resource_group.main.name
  location                   = azurerm_resource_group.main.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 90
  purge_protection_enabled   = false
  rbac_authorization_enabled = false

  public_network_access_enabled = var.public_network_access

  tags = local.tags
}

# -----------------------------------------------------------------------------
# Key Vault Access Policies — all managed as separate resources.
#
# IMPORTANT: Do NOT use inline access_policy blocks inside azurerm_key_vault.
# The azurerm provider treats inline policies as authoritative — any in-place
# update to the KV resource will remove externally-managed policies. Using
# separate azurerm_key_vault_access_policy resources avoids this conflict.
#
# With managed network isolation (AllowOnlyApprovedOutbound), Azure ML cannot
# auto-create its own KV access policies. Grant explicit access to:
# 1. Deployer (current user) — full administrative access
# 2. Hub SystemAssigned identity — workspace operations
# 3. Hub primary UAI (CMK identity) — used as primary identity for operations
# 4. Azure ML first-party SP / Project identity — platform + endpoint key mgmt
# -----------------------------------------------------------------------------

resource "azurerm_key_vault_access_policy" "deployer" {
  key_vault_id = azurerm_key_vault.ml.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions         = ["Get", "List", "Create", "Delete", "Update", "Purge", "Recover"]
  secret_permissions      = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
  certificate_permissions = ["Get", "List", "Create", "Delete", "Update", "Purge", "Recover"]
}

resource "azurerm_key_vault_access_policy" "hub_system_identity" {
  key_vault_id = azurerm_key_vault.ml.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azapi_resource.ai_hub.identity[0].principal_id

  key_permissions         = ["Get", "List", "Create", "Delete", "Update", "Recover", "WrapKey", "UnwrapKey"]
  secret_permissions      = ["Get", "List", "Set", "Delete", "Recover"]
  certificate_permissions = ["Get", "List", "Create", "Delete", "Update", "Recover"]
}

resource "azurerm_key_vault_access_policy" "hub_uai" {
  key_vault_id = azurerm_key_vault.ml.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_user_assigned_identity.cmk.principal_id

  key_permissions         = ["Get", "List", "Create", "Delete", "Update", "Recover", "WrapKey", "UnwrapKey"]
  secret_permissions      = ["Get", "List", "Set", "Delete", "Recover"]
  certificate_permissions = ["Get", "List", "Create", "Delete", "Update", "Recover"]
}

# The AI Foundry Project's system-assigned identity and the Azure ML first-party
# service principal share the same object ID in the tenant. Azure KV enforces one
# access policy per object ID, so we manage a single policy that covers both:
# - Platform-level secret management (Azure ML SP)
# - Endpoint key management (Project identity)
resource "azurerm_key_vault_access_policy" "azure_ml_service" {
  key_vault_id = azurerm_key_vault.ml.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = var.azure_ml_sp_object_id

  key_permissions    = ["Get", "List", "WrapKey", "UnwrapKey"]
  secret_permissions = ["Get", "List", "Set"]
}
