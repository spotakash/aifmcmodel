# =============================================================================
# Storage Account — shared by all ML workspaces
# =============================================================================

resource "azurerm_storage_account" "ml" {
  name                             = local.storage_account_name
  resource_group_name              = azurerm_resource_group.main.name
  location                         = azurerm_resource_group.main.location
  account_tier                     = "Standard"
  account_replication_type         = "LRS"
  account_kind                     = "StorageV2"
  min_tls_version                  = "TLS1_2"
  allow_nested_items_to_be_public  = false
  cross_tenant_replication_enabled = false
  public_network_access_enabled    = var.public_network_access

  tags = local.tags

  # blob_properties {
  #   cors_rule {
  #     allowed_headers    = ["*"]
  #     allowed_methods    = ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "POST", "PATCH"]
  #     allowed_origins    = ["https://mlworkspace.azure.ai", "https://ml.azure.com", "https://*.ml.azure.com", "https://ai.azure.com", "https://*.ai.azure.com"]
  #     exposed_headers    = ["*"]
  #     max_age_in_seconds = 1800
  #   }
  # }

  share_properties {
    # cors_rule {
    #   allowed_headers    = ["*"]
    #   allowed_methods    = ["GET", "HEAD", "PUT", "DELETE", "OPTIONS", "POST"]
    #   allowed_origins    = ["https://mlworkspace.azure.ai", "https://ml.azure.com", "https://*.ml.azure.com", "https://ai.azure.com", "https://*.ai.azure.com"]
    #   exposed_headers    = ["*"]
    #   max_age_in_seconds = 1800
    # }

    retention_policy {
      days = 7
    }
  }
}
