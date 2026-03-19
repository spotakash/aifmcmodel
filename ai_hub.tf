# =============================================================================
# AI Foundry Hub — Central hub workspace
#
# Uses azurerm_ai_foundry (native provider support).
# The Hub owns shared resources (Storage, KV, ACR, App Insights).
# =============================================================================

# -----------------------------------------------------------------------------
# Purge any soft-deleted hub with the same name before re-creating.
# Azure ML returns 400 "Soft-deleted workspace exists" if one lingers.
# -----------------------------------------------------------------------------
resource "terraform_data" "purge_soft_deleted_ai_hub" {
  input = local.ai_hub_name

  provisioner "local-exec" {
    command = "az rest --method DELETE --url 'https://management.azure.com/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${local.resource_group_name}/providers/Microsoft.MachineLearningServices/workspaces/${local.ai_hub_name}?api-version=2024-04-01&forceToPurge=true' 2>/dev/null || true; sleep 30"
  }

  depends_on = [azurerm_resource_group.main]
}

# resource "azurerm_ai_foundry" "ai_hub" {
#   name                = local.ai_hub_name
#   location            = azurerm_resource_group.main.location
#   resource_group_name = azurerm_resource_group.main.name
#   storage_account_id  = azurerm_storage_account.ml.id
#   key_vault_id        = azurerm_key_vault.ml.id

#   application_insights_id = azurerm_application_insights.ml.id
#   container_registry_id   = azurerm_container_registry.ml.id

#   friendly_name         = local.ai_hub_name
#   description           = "AI Foundry Hub for ${var.project_name}"
#   public_network_access = local.public_network_access

#   managed_network {
#     isolation_mode = "AllowOnlyApprovedOutbound"
#   }

#   identity {
#     type         = "SystemAssigned, UserAssigned"
#     identity_ids = [azurerm_user_assigned_identity.cmk.id]
#   }

#   encryption {
#     key_id                    = azurerm_key_vault_key.cmk.id
#     key_vault_id              = azurerm_key_vault.cmk.id
#     user_assigned_identity_id = azurerm_user_assigned_identity.cmk.id
#   }

#   primary_user_assigned_identity = azurerm_user_assigned_identity.cmk.id

#   tags = local.tags

#   depends_on = [
#     terraform_data.purge_soft_deleted_ai_hub,
#     time_sleep.wait_for_cmk_rbac,
#   ]
# }

resource "azapi_resource" "ai_hub" {
  name      = local.ai_hub_name
  type      = "Microsoft.MachineLearningServices/workspaces@2025-01-01-preview"
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id
  tags      = local.tags

  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.cmk.id]
  }

  body = {
    kind = "Hub"
    sku = {
      name = "Basic"
      tier = "Basic"
    }
    properties = {
      friendlyName                = local.ai_hub_name
      description                 = "AI Foundry Hub for ${var.project_name}"
      storageAccount              = azurerm_storage_account.ml.id
      keyVault                    = azurerm_key_vault.ml.id
      applicationInsights         = azurerm_application_insights.ml.id
      containerRegistry           = azurerm_container_registry.ml.id
      publicNetworkAccess         = local.public_network_access
      hbiWorkspace                = false
      v1LegacyMode                = false
      primaryUserAssignedIdentity = azurerm_user_assigned_identity.cmk.id

      managedNetwork = {
        isolationMode = "AllowOnlyApprovedOutbound"
      }
      enableServiceSideCMKEncryption = true
      encryption = {
        status = "Enabled"
        keyVaultProperties = {
          keyVaultArmId    = azurerm_key_vault.cmk.id
          keyIdentifier    = azurerm_key_vault_key.cmk.id
          identityClientId = azurerm_user_assigned_identity.cmk.client_id
        }
      }
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true

  lifecycle {
    ignore_changes = [
      body.properties.associatedWorkspaces,
    ]
  }

  depends_on = [
    terraform_data.purge_soft_deleted_ai_hub,
    time_sleep.wait_for_cmk_rbac,
  ]
}

# -----------------------------------------------------------------------------
# RBAC: Managed network provisioning requires PE approval permissions.
# After April 30 2025, Azure no longer auto-grants these. Per official docs
# (https://aka.ms/azureaipeapproval), the recommended role is:
#   "Azure AI Enterprise Network Connection Approver"
# This covers PE approval for Storage, KV, ACR, Cosmos DB, AI Search, etc.
#
# Since primary_user_assigned_identity is set (CMK identity), Azure uses
# that identity for workspace operations including network provisioning.
# The PE Approver role alone doesn't include resource-level read actions
# (e.g. Microsoft.ContainerRegistry/registries/read), so the identity
# also needs Reader to discover resources before approving PE connections.
# -----------------------------------------------------------------------------
resource "azurerm_role_assignment" "hub_network_approver_system" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Azure AI Enterprise Network Connection Approver"
  principal_id         = azapi_resource.ai_hub.identity[0].principal_id
}

resource "azurerm_role_assignment" "hub_network_approver_uai" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Azure AI Enterprise Network Connection Approver"
  principal_id         = azurerm_user_assigned_identity.cmk.principal_id
}

resource "azurerm_role_assignment" "hub_uai_reader" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.cmk.principal_id
}

resource "time_sleep" "wait_for_hub_rbac" {
  depends_on = [
    azurerm_role_assignment.hub_network_approver_system,
    azurerm_role_assignment.hub_network_approver_uai,
    azurerm_role_assignment.hub_uai_reader,
  ]
  create_duration = "120s"
}

# -----------------------------------------------------------------------------
# FQDN outbound rules — Required for HuggingFace model deployments.
# AllowOnlyApprovedOutbound blocks all egress by default. The model container
# image is pulled from Docker Hub, and model artifacts from HuggingFace CDN.
# Adding FQDN rules triggers Azure Firewall (Standard SKU) creation.
# See: https://aka.ms/azureml-managed-network#scenario-use-huggingface-models
# -----------------------------------------------------------------------------
resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "docker_io" {
  name             = "allow-docker-io"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "docker.io"
  depends_on       = [time_sleep.wait_for_hub_rbac]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "docker_io_wildcard" {
  name             = "allow-docker-io-wildcard"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "*.docker.io"
  depends_on       = [time_sleep.wait_for_hub_rbac]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "docker_com" {
  name             = "allow-docker-com"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "*.docker.com"
  depends_on       = [time_sleep.wait_for_hub_rbac]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "cloudflare_docker" {
  name             = "allow-cloudflare-docker"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "production.cloudflare.docker.com"
  depends_on       = [time_sleep.wait_for_hub_rbac]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "auth0" {
  name             = "allow-auth0"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "cdn.auth0.com"
  depends_on       = [time_sleep.wait_for_hub_rbac]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "huggingface" {
  name             = "allow-huggingface-lfs"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "cdn-lfs.huggingface.co"
  depends_on       = [time_sleep.wait_for_hub_rbac]
}

# -----------------------------------------------------------------------------
# Provision managed network — AllowOnlyApprovedOutbound creates a managed VNet.
# FQDN outbound rules trigger Azure Firewall (Standard SKU) creation.
# Provisioning is lazy by default; this triggers it immediately so the network
# (VNet + Firewall + PE connections) is ready before endpoints are created.
# Azure auto-creates required outbound rules for workspace resources (Storage,
# ACR, KV, App Insights) and essential services (AAD, ARM, MCR, Azure ML).
# azapi_resource_action handles the Azure LRO (async) tracking natively —
# it won't complete until the managed network is fully provisioned.
# -----------------------------------------------------------------------------
resource "azapi_resource_action" "provision_managed_network" {
  type        = "Microsoft.MachineLearningServices/workspaces@2025-01-01-preview"
  resource_id = azapi_resource.ai_hub.id
  action      = "provisionManagedNetwork"

  body = {
    includeSpark = false
  }

  depends_on = [
    time_sleep.wait_for_hub_rbac,
    azurerm_machine_learning_workspace_network_outbound_rule_fqdn.docker_io,
    azurerm_machine_learning_workspace_network_outbound_rule_fqdn.docker_io_wildcard,
    azurerm_machine_learning_workspace_network_outbound_rule_fqdn.docker_com,
    azurerm_machine_learning_workspace_network_outbound_rule_fqdn.cloudflare_docker,
    azurerm_machine_learning_workspace_network_outbound_rule_fqdn.auth0,
    azurerm_machine_learning_workspace_network_outbound_rule_fqdn.huggingface,
  ]
}
