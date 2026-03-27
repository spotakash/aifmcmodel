# =============================================================================
# Azure Bastion — Standard SKU for secure RDP/SSH to jumpbox VM
#
# Deployed only when public_network_access = false (private mode).
# Standard SKU supports host scaling, native client, and IP-based connection.
# Requires dedicated AzureBastionSubnet (/26 minimum) and Standard SKU PIP.
# =============================================================================

resource "azurerm_public_ip" "bastion" {
  count               = var.public_network_access ? 0 : 1
  name                = local.bastion_pip_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "main" {
  count               = var.public_network_access ? 0 : 1
  name                = local.bastion_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  sku                 = "Standard"
  tags                = local.tags

  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }
}
