# =============================================================================
# Customer-Managed Key (CMK) — Separate Key Vault + RSA Key for AI Hub encryption
#
# CMK Key Vault lives in its own resource group (same region) with
# purge protection enabled (required for CMK). A User-Assigned Managed
# Identity is created to grant the AI Hub access to the encryption key.
# =============================================================================

# --- CMK Resource Group ---
resource "azurerm_resource_group" "cmk" {
  name     = local.cmk_resource_group_name
  location = var.location
  tags     = local.tags
}

# --- User-Assigned Managed Identity for CMK access ---
resource "azurerm_user_assigned_identity" "cmk" {
  name                = local.cmk_identity_name
  resource_group_name = azurerm_resource_group.cmk.name
  location            = azurerm_resource_group.cmk.location
  tags                = local.tags
}

# --- CMK Key Vault (purge protection required for CMK) ---
resource "azurerm_key_vault" "cmk" {
  name                       = local.cmk_key_vault_name
  resource_group_name        = azurerm_resource_group.cmk.name
  location                   = azurerm_resource_group.cmk.location
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 90
  purge_protection_enabled   = true
  rbac_authorization_enabled = true

  # CMK KV must always be reachable by the deployer (Terraform runs outside
  # the VNet). Only the AI Hub identity accesses this KV at runtime, and it
  # uses Azure backbone — public access here does not weaken security.
  public_network_access_enabled = true

  tags = local.tags
}

# --- RBAC: Deployer gets Key Vault Administrator on CMK vault ---
resource "azurerm_role_assignment" "cmk_deployer_admin" {
  scope                = azurerm_key_vault.cmk.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

# --- RBAC: User-Assigned Identity gets Crypto User on CMK vault ---
resource "azurerm_role_assignment" "cmk_identity_crypto" {
  scope                = azurerm_key_vault.cmk.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_user_assigned_identity.cmk.principal_id
}

# --- RBAC: User-Assigned Identity gets Reader on CMK vault ---
# Required for Microsoft.KeyVault/vaults/read which Crypto User doesn't include
resource "azurerm_role_assignment" "cmk_identity_reader" {
  scope                = azurerm_key_vault.cmk.id
  role_definition_name = "Reader"
  principal_id         = azurerm_user_assigned_identity.cmk.principal_id
}

# --- Wait for RBAC propagation before Hub uses the CMK identity ---
resource "time_sleep" "wait_for_cmk_rbac" {
  depends_on = [
    azurerm_role_assignment.cmk_identity_crypto,
    azurerm_role_assignment.cmk_identity_reader,
    azurerm_role_assignment.cmk_deployer_admin,
  ]
  create_duration = "60s"
}

# --- RSA 2048 encryption key ---
resource "azurerm_key_vault_key" "cmk" {
  name         = local.cmk_key_name
  key_vault_id = azurerm_key_vault.cmk.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "decrypt",
    "encrypt",
    "sign",
    "unwrapKey",
    "verify",
    "wrapKey",
  ]

  depends_on = [azurerm_role_assignment.cmk_deployer_admin, time_sleep.wait_for_cmk_rbac]
}
