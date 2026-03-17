# =============================================================================
# Cognitive Services — AI Services account
# =============================================================================

resource "azurerm_cognitive_account" "ai_services" {
  name                  = local.cognitive_account_name
  resource_group_name   = azurerm_resource_group.main.name
  location              = azurerm_resource_group.main.location
  kind                  = "AIServices"
  sku_name              = "S0"
  custom_subdomain_name = replace(local.cognitive_account_name, "-", "")

  local_auth_enabled            = false
  public_network_access_enabled = var.public_network_access

  tags = local.tags
}
