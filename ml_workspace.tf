# =============================================================================
# Standard Azure ML Workspace (kind = "Default")
#
# This is the classic AML workspace for experimentation, training, etc.
# Uses azurerm since standard workspaces are fully supported.
# =============================================================================

# -----------------------------------------------------------------------------
# Purge any soft-deleted workspace with the same name before re-creating.
# The Azure ML API returns 400 "Soft-deleted workspace exists" if one exists.
# This fires only on initial create (triggers_replace = name).
# -----------------------------------------------------------------------------
resource "terraform_data" "purge_soft_deleted_ml_workspace" {
  input = local.ml_workspace_name

  provisioner "local-exec" {
    command = "az rest --method DELETE --url 'https://management.azure.com/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${local.resource_group_name}/providers/Microsoft.MachineLearningServices/workspaces/${local.ml_workspace_name}?api-version=2024-04-01&forceToPurge=true' 2>/dev/null || true; sleep 30"
  }

  depends_on = [azurerm_resource_group.main]
}

resource "azurerm_machine_learning_workspace" "ml" {
  name                          = local.ml_workspace_name
  resource_group_name           = azurerm_resource_group.main.name
  location                      = azurerm_resource_group.main.location
  application_insights_id       = azurerm_application_insights.ml.id
  key_vault_id                  = azurerm_key_vault.ml.id
  storage_account_id            = azurerm_storage_account.ml.id
  container_registry_id         = azurerm_container_registry.ml.id
  public_network_access_enabled = var.public_network_access
  friendly_name                 = local.ml_workspace_name
  sku_name                      = "Basic"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags

  depends_on = [terraform_data.purge_soft_deleted_ml_workspace]
}

# =============================================================================
# Compute Instance (optional) — for development / experimentation
# =============================================================================

resource "azurerm_machine_learning_compute_instance" "dev" {
  count = var.create_compute_instance ? 1 : 0

  name                          = local.compute_instance_name
  machine_learning_workspace_id = azurerm_machine_learning_workspace.ml.id
  virtual_machine_size          = "Standard_D13_v2"

  authorization_type = "personal"

  tags = local.tags
}
