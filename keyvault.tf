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

  # Grant deployer full access
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions         = ["Get", "List", "Create", "Delete", "Update", "Purge", "Recover"]
    secret_permissions      = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
    certificate_permissions = ["Get", "List", "Create", "Delete", "Update", "Purge", "Recover"]
  }

  tags = local.tags
}

# NOTE: ML workspace and AI Hub identities auto-create their own KV access
# policies during workspace provisioning. No explicit policies needed.
