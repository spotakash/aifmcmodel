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

# =============================================================================
# Diagnostic Settings — Online Endpoint (inference logs + traffic metrics)
#
# AmlOnlineEndpoint* log categories only exist on the onlineEndpoints child
# resource, not on the Hub or Project workspace. Explicit category names are
# used instead of the "allLogs" category group for reliability.
# log_analytics_destination_type = "Dedicated" sends data to resource-specific
# tables (AmlOnlineEndpointTrafficLog, etc.) instead of AzureDiagnostics.
# =============================================================================

resource "azurerm_monitor_diagnostic_setting" "online_endpoint" {
  name                           = "diag-${local.endpoint_name}"
  target_resource_id             = azapi_resource.online_endpoint.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.ml.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "AmlOnlineEndpointConsoleLog"
  }

  enabled_log {
    category = "AmlOnlineEndpointTrafficLog"
  }

  enabled_log {
    category = "AmlOnlineEndpointEventLog"
  }

  enabled_metric {
    category = "Traffic"
  }
}

# =============================================================================
# Diagnostic Settings — AI Foundry Project workspace (deployment & run events)
# =============================================================================

resource "azurerm_monitor_diagnostic_setting" "ai_project" {
  name                           = "diag-${local.ai_project_name}"
  target_resource_id             = azurerm_ai_foundry_project.ai_project.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.ml.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category = "DeploymentReadEvent"
  }

  enabled_log {
    category = "DeploymentEventACI"
  }

  enabled_log {
    category = "DeploymentEventAKS"
  }

  enabled_log {
    category = "InferencingOperationAKS"
  }

  enabled_log {
    category = "InferencingOperationACI"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}
