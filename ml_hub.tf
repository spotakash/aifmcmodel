# =============================================================================
# AI Foundry Hub — Central hub workspace (kind = "Hub")
#
# Uses azapi because AI Foundry Hub requires workspaceHubConfig and
# associatedWorkspaces which are not fully supported in azurerm.
# =============================================================================

resource "azapi_resource" "ai_hub" {
  type      = "Microsoft.MachineLearningServices/workspaces@2025-01-01-preview"
  name      = local.ai_hub_name
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id

  tags = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "Hub"
    sku = {
      name = "Basic"
      tier = "Basic"
    }
    properties = {
      friendlyName                   = local.ai_hub_name
      description                    = "AI Foundry Hub for ${var.project_name}"
      storageAccount                 = azurerm_storage_account.ml.id
      keyVault                       = azurerm_key_vault.ml.id
      applicationInsights            = azurerm_application_insights.ml.id
      containerRegistry              = azurerm_container_registry.ml.id
      hbiWorkspace                   = false
      v1LegacyMode                   = false
      publicNetworkAccess            = local.public_network_access
      discoveryUrl                   = "https://${var.location}.api.azureml.ms/discovery"
      enableDataIsolation            = true
      enableServiceSideCMKEncryption = false
      allowRoleAssignmentOnRG        = true
      systemDatastoresAuthMode       = "accesskey"

      managedNetwork = {
        isolationMode = "Disabled"
      }

      workspaceHubConfig = {
        defaultWorkspaceResourceGroup = azurerm_resource_group.main.id
      }
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true

  lifecycle {
    ignore_changes = [
      body.properties.associatedWorkspaces,
    ]
  }
}
