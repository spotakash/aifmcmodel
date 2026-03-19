# =============================================================================
# Azure Container Registry — shared image registry for ML workspaces
# =============================================================================

resource "azurerm_container_registry" "ml" {
  name                = local.container_registry_name
  resource_group_name = azurerm_resource_group.main.name
  location            = azurerm_resource_group.main.location
  sku                 = "Premium"
  admin_enabled       = true

  public_network_access_enabled = var.public_network_access
  zone_redundancy_enabled       = false

  tags = local.tags
}
