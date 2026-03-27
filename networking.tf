# =============================================================================
# Virtual Network & Subnets — Private connectivity for model endpoint access
#
# Deployed only when public_network_access = false (private mode).
#
# Subnet sizing follows Microsoft minimum requirements:
#   AzureBastionSubnet: /26 — Azure-mandated minimum (docs: configuration-settings#subnet)
#   PrivateEndpoint:    /27 — 27 usable IPs for PE NICs (min ~31 IP block)
#   Jumpbox:            /29 — 3 usable IPs, smallest usable subnet for 1 VM
#   Spare:              /24 — 251 usable IPs for future workloads
#
# Azure reserves 5 IPs per subnet (first 4 + last 1).
# =============================================================================

resource "azurerm_virtual_network" "main" {
  count               = var.public_network_access ? 0 : 1
  name                = local.vnet_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  address_space       = [var.vnet_address_space]
  tags                = local.tags
}

resource "azurerm_subnet" "bastion" {
  count                = var.public_network_access ? 0 : 1
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = [local.bastion_subnet_cidr]
}

resource "azurerm_subnet" "private_endpoint" {
  count                = var.public_network_access ? 0 : 1
  name                 = "snet-private-endpoint"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = [local.pe_subnet_cidr]
}

resource "azurerm_subnet" "jumpbox" {
  count                = var.public_network_access ? 0 : 1
  name                 = "snet-jumpbox"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = [local.jumpbox_subnet_cidr]
}

resource "azurerm_subnet" "spare" {
  count                = var.public_network_access ? 0 : 1
  name                 = "snet-spare"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main[0].name
  address_prefixes     = [local.spare_subnet_cidr]
}
