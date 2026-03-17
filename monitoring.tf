# =============================================================================
# Log Analytics Workspace
# =============================================================================

resource "azurerm_log_analytics_workspace" "ml" {
  name                = local.log_analytics_workspace_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "PerGB2018"
  retention_in_days   = 30

  tags = local.tags
}

# =============================================================================
# Application Insights — linked to Log Analytics
# =============================================================================

resource "azurerm_application_insights" "ml" {
  name                = local.application_insights_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  workspace_id        = azurerm_log_analytics_workspace.ml.id
  application_type    = "web"

  tags = local.tags
}

# =============================================================================
# Diagnostic Settings — send platform logs & metrics to Log Analytics
# =============================================================================

resource "azurerm_monitor_diagnostic_setting" "keyvault" {
  name                       = "diag-${local.key_vault_name}"
  target_resource_id         = azurerm_key_vault.ml.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.ml.id

  enabled_log {
    category = "AuditEvent"
  }

  enabled_log {
    category = "AzurePolicyEvaluationDetails"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_monitor_diagnostic_setting" "storage" {
  name                       = "diag-${local.storage_account_name}"
  target_resource_id         = azurerm_storage_account.ml.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.ml.id

  enabled_metric {
    category = "Transaction"
  }
}

resource "azurerm_monitor_diagnostic_setting" "storage_blob" {
  name                       = "diag-${local.storage_account_name}-blob"
  target_resource_id         = "${azurerm_storage_account.ml.id}/blobServices/default/"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.ml.id

  enabled_log {
    category = "StorageRead"
  }

  enabled_log {
    category = "StorageWrite"
  }

  enabled_log {
    category = "StorageDelete"
  }

  enabled_metric {
    category = "Transaction"
  }
}
