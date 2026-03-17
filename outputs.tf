# =============================================================================
# Outputs
# =============================================================================

# --- Resource Group ---
output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.main.name
}

output "resource_group_id" {
  description = "ID of the resource group"
  value       = azurerm_resource_group.main.id
}

# --- Storage Account ---
output "storage_account_id" {
  description = "ID of the storage account"
  value       = azurerm_storage_account.ml.id
}

output "storage_account_name" {
  description = "Name of the storage account"
  value       = azurerm_storage_account.ml.name
}

# --- Key Vault ---
output "key_vault_id" {
  description = "ID of the Key Vault"
  value       = azurerm_key_vault.ml.id
}

output "key_vault_uri" {
  description = "URI of the Key Vault"
  value       = azurerm_key_vault.ml.vault_uri
}

# --- Monitoring ---
output "log_analytics_workspace_id" {
  description = "ID of the Log Analytics workspace"
  value       = azurerm_log_analytics_workspace.ml.id
}

output "application_insights_id" {
  description = "ID of the Application Insights"
  value       = azurerm_application_insights.ml.id
}

output "application_insights_connection_string" {
  description = "Connection string for Application Insights"
  value       = azurerm_application_insights.ml.connection_string
  sensitive   = true
}

# --- Container Registry ---
output "container_registry_id" {
  description = "ID of the Container Registry"
  value       = azurerm_container_registry.ml.id
}

output "container_registry_login_server" {
  description = "Login server for the Container Registry"
  value       = azurerm_container_registry.ml.login_server
}

# --- Cognitive Services ---
output "cognitive_account_id" {
  description = "ID of the Cognitive Services account"
  value       = azurerm_cognitive_account.ai_services.id
}

output "cognitive_account_endpoint" {
  description = "Endpoint of the Cognitive Services account"
  value       = azurerm_cognitive_account.ai_services.endpoint
}

# --- AI Foundry Hub ---
output "ai_hub_id" {
  description = "ID of the AI Foundry Hub workspace"
  value       = azapi_resource.ai_hub.id
}

# --- AI Foundry Project ---
output "ai_project_id" {
  description = "ID of the AI Foundry Project workspace"
  value       = azapi_resource.ai_project.id
}

# --- Standard ML Workspace ---
output "ml_workspace_id" {
  description = "ID of the standard ML workspace"
  value       = azurerm_machine_learning_workspace.ml.id
}

# --- Online Endpoint ---
output "online_endpoint_id" {
  description = "ID of the managed online endpoint"
  value       = azapi_resource.online_endpoint.id
}

output "online_endpoint_name" {
  description = "Name of the managed online endpoint"
  value       = azapi_resource.online_endpoint.name
}

# --- Model Deployment ---
output "model_deployment_id" {
  description = "ID of the model deployment"
  value       = azapi_resource.model_deployment.id
}

output "model_deployment_name" {
  description = "Name of the model deployment"
  value       = azapi_resource.model_deployment.name
}

output "resolved_instance_type" {
  description = "Auto-selected VM SKU based on model (CPU vs GPU)"
  value       = local.resolved_instance_type
}

output "model_short_name" {
  description = "Model short name extracted from model_id"
  value       = local.model_short_name
}
