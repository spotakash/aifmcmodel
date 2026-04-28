# =============================================================================
# AI Foundry Hub — Central hub workspace
#
# Uses azapi_resource (Microsoft.MachineLearningServices/workspaces) with
# kind=Hub. Provides CMK encryption, AllowOnlyApprovedOutbound managed
# network, and FQDN outbound rules for HuggingFace model downloads.
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
      body.properties.hbiWorkspace,
      body.properties.publicNetworkAccess,
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
#
# Uses azurerm_machine_learning_workspace_network_outbound_rule_fqdn.
# Known behavior: azurerm read-back sometimes returns empty, so rules may
# not persist in state. This is acceptable — on next apply, Terraform
# silently recreates any missing rules (idempotent PUT). This self-heals
# if Azure's managed network reconciliation removes rules.
#
# Rules are created AFTER managed network provisioning. The
# provisionManagedNetwork action creates the Azure Firewall from scratch;
# rules must be applied to the live Firewall to persist reliably.
# See: https://aka.ms/azureml-managed-network#scenario-use-huggingface-models
# -----------------------------------------------------------------------------
resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "docker_io" {
  name             = "allow-docker-io"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "docker.io"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "docker_io_wildcard" {
  name             = "allow-docker-io-wildcard"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "*.docker.io"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "docker_com" {
  name             = "allow-docker-com"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "*.docker.com"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "cloudflare_docker" {
  name             = "allow-cloudflare-docker"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "production.cloudflare.docker.com"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "auth0" {
  name             = "allow-auth0"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "cdn.auth0.com"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "huggingface" {
  name             = "allow-huggingface-lfs"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "cdn-lfs.huggingface.co"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "huggingface_co" {
  name             = "allow-huggingface-co"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "huggingface.co"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "huggingface_co_wildcard" {
  name             = "allow-huggingface-co-wildcard"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "*.huggingface.co"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "xethub_hf_co" {
  name             = "allow-xethub-hf-co"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "xethub.hf.co"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

resource "azurerm_machine_learning_workspace_network_outbound_rule_fqdn" "xethub_hf_co_wildcard" {
  name             = "allow-xethub-hf-co-wildcard"
  workspace_id     = azapi_resource.ai_hub.id
  destination_fqdn = "*.xethub.hf.co"
  depends_on       = [azapi_resource_action.provision_managed_network]
}

# --- Removed blocks: clean transition from azapi_resource FQDN rules ------
# These prevent Terraform from trying to delete rules still in state from ---
# previous provider iterations. Safe to remove after one successful apply. --
removed {
  from = azapi_resource.fqdn_docker_io
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_docker_io_wildcard
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_docker_com
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_cloudflare_docker
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_auth0
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_huggingface_lfs
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_huggingface_co
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_huggingface_co_wildcard
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_xethub_hf_co
  lifecycle { destroy = false }
}
removed {
  from = azapi_resource.fqdn_xethub_hf_co_wildcard
  lifecycle { destroy = false }
}

# -----------------------------------------------------------------------------
# Provision managed network — AllowOnlyApprovedOutbound creates a managed VNet.
# This triggers immediately so the network (VNet + Firewall + PE connections)
# is ready before FQDN rules and endpoints are created.
# Azure auto-creates required outbound rules for workspace resources (Storage,
# ACR, KV, App Insights) and essential services (AAD, ARM, MCR, Azure ML).
# azapi_resource_action handles the Azure LRO (async) tracking natively —
# it won't complete until the managed network is fully provisioned.
#
# IMPORTANT: FQDN rules are created AFTER this step, not before. The
# provisionManagedNetwork action creates the Azure Firewall from scratch and
# overwrites FQDN rules that existed beforehand. By provisioning first and
# then adding FQDN rules, they are applied to a live firewall reliably.
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
  ]
}
