# =============================================================================
# Data Science VM (Windows Server 2022) — Jumpbox for private endpoint access
#
# Deployed only when public_network_access = false (private mode).
# No public IP — accessed exclusively via Azure Bastion.
# Image: Microsoft Data Science VM for Windows Server 2022
# Default size: Standard_D4s_v5 (4 vCPU, 16 GB RAM)
# =============================================================================

resource "azurerm_network_interface" "jumpbox" {
  count               = var.public_network_access ? 0 : 1
  name                = local.jumpbox_nic_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.jumpbox[0].id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_windows_virtual_machine" "jumpbox" {
  count               = var.public_network_access ? 0 : 1
  name                = local.jumpbox_name
  computer_name       = "jumpbox"
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  size                = var.jumpbox_vm_size
  admin_username      = var.jumpbox_admin_username
  admin_password      = var.jumpbox_admin_password
  tags                = local.tags

  network_interface_ids = [
    azurerm_network_interface.jumpbox[0].id,
  ]

  os_disk {
    name                 = local.jumpbox_os_disk
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "microsoft-dsvm"
    offer     = "dsvm-win-2022"
    sku       = "winserver-2022"
    version   = "latest"
  }

}
