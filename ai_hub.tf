# =============================================================================
# AI Foundry Hub — Central hub workspace
#
# Uses azurerm_ai_foundry (native provider support).
# The Hub owns shared resources (Storage, KV, ACR, App Insights).
# =============================================================================

# -----------------------------------------------------------------------------
# Purge any soft-deleted hub with the same name before re-creating.
# Azure ML returns 400 "Soft-deleted workspace exists" if one lingers.
# -----------------------------------------------------------------------------
resource "terraform_data" "purge_soft_deleted_ai_hub" {
  input = local.ai_hub_name

  provisioner "local-exec" {
    command = "az rest --method DELETE --url 'https://management.azure.com/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${local.resource_group_name}/providers/Microsoft.MachineLearningServices/workspaces/${local.ai_hub_name}?api-version=2024-04-01&forceToPurge=true' 2>/dev/null || true; sleep 30"
  }

  depends_on = [azurerm_resource_group.main]
}

resource "azurerm_ai_foundry" "ai_hub" {
  name                = local.ai_hub_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  storage_account_id  = azurerm_storage_account.ml.id
  key_vault_id        = azurerm_key_vault.ml.id

  application_insights_id = azurerm_application_insights.ml.id
  container_registry_id   = azurerm_container_registry.ml.id

  friendly_name         = local.ai_hub_name
  description           = "AI Foundry Hub for ${var.project_name}"
  public_network_access = local.public_network_access

  managed_network {
    isolation_mode = "Disabled"
  }

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags

  depends_on = [terraform_data.purge_soft_deleted_ai_hub]
}
