# =============================================================================
# Private Endpoint + DNS — AI Foundry Hub workspace private connectivity
#
# Deployed only when public_network_access = false (private mode).
# Subresource: amlworkspace — covers workspace API and scoring endpoint access.
# DNS zones auto-resolve workspace and scoring URLs to private IPs.
#
# DNS Zones:
#   privatelink.api.azureml.ms      — workspace API + scoring endpoints
#   privatelink.notebooks.azure.net — notebook service
# =============================================================================

# --- Private DNS Zones ---

resource "azurerm_private_dns_zone" "azureml_api" {
  count               = var.public_network_access ? 0 : 1
  name                = "privatelink.api.azureml.ms"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone" "notebooks" {
  count               = var.public_network_access ? 0 : 1
  name                = "privatelink.notebooks.azure.net"
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags
}

# --- VNet Links ---

resource "azurerm_private_dns_zone_virtual_network_link" "azureml_api" {
  count                 = var.public_network_access ? 0 : 1
  name                  = "vnetlink-azureml-api"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.azureml_api[0].name
  virtual_network_id    = azurerm_virtual_network.main[0].id
  registration_enabled  = false
  tags                  = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "notebooks" {
  count                 = var.public_network_access ? 0 : 1
  name                  = "vnetlink-notebooks"
  resource_group_name   = azurerm_resource_group.main.name
  private_dns_zone_name = azurerm_private_dns_zone.notebooks[0].name
  virtual_network_id    = azurerm_virtual_network.main[0].id
  registration_enabled  = false
  tags                  = local.tags
}

# --- Private Endpoint for AI Foundry Hub ---

resource "azurerm_private_endpoint" "ai_hub" {
  count               = var.public_network_access ? 0 : 1
  name                = local.pe_hub_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  subnet_id           = azurerm_subnet.private_endpoint[0].id
  tags                = local.tags

  private_service_connection {
    name                           = "psc-${local.safe_prefix}-hub"
    private_connection_resource_id = azapi_resource.ai_hub.id
    subresource_names              = ["amlworkspace"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name = "default"
    private_dns_zone_ids = [
      azurerm_private_dns_zone.azureml_api[0].id,
      azurerm_private_dns_zone.notebooks[0].id,
    ]
  }
}
