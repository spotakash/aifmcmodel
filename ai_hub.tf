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
# Adding FQDN rules triggers Azure Firewall (Standard SKU) creation.
# See: https://aka.ms/azureml-managed-network#scenario-use-huggingface-models
#
# IMPORTANT: Rules are created AFTER managed network provisioning. The
# provisionManagedNetwork action creates the Azure Firewall from scratch and
# can overwrite/lose FQDN rules that were created beforehand. By creating
# rules after provisioning, they are applied to a live firewall reliably.
#
# Uses azapi_resource instead of azurerm because the azurerm provider has a
# bug where FQDN rules are created in Azure but the read-back returns empty,
# causing Terraform to drop them from state.
# -----------------------------------------------------------------------------
resource "azapi_resource" "fqdn_docker_io" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-docker-io"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "docker.io"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_docker_io_wildcard" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-docker-io-wildcard"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "*.docker.io"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_docker_com" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-docker-com"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "*.docker.com"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_cloudflare_docker" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-cloudflare-docker"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "production.cloudflare.docker.com"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_auth0" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-auth0"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "cdn.auth0.com"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_huggingface_lfs" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-huggingface-lfs"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "cdn-lfs.huggingface.co"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_huggingface_co" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-huggingface-co"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "huggingface.co"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_huggingface_co_wildcard" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-huggingface-co-wildcard"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "*.huggingface.co"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_xethub_hf_co" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-xethub-hf-co"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "xethub.hf.co"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

resource "azapi_resource" "fqdn_xethub_hf_co_wildcard" {
  type      = "Microsoft.MachineLearningServices/workspaces/outboundRules@2025-01-01-preview"
  name      = "allow-xethub-hf-co-wildcard"
  parent_id = azapi_resource.ai_hub.id

  body = {
    properties = {
      type        = "FQDN"
      category    = "UserDefined"
      destination = "*.xethub.hf.co"
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true
  depends_on                = [azapi_resource_action.provision_managed_network]
}

# --- Removed blocks: migrate FQDN rules from azurerm to azapi without -----
# --- deleting them in Azure. The azurerm provider had a bug where rules ----
# --- were silently lost from state. These blocks can be removed after the --
# --- first successful apply with the new azapi resources. ------------------
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.docker_io
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.docker_io_wildcard
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.docker_com
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.cloudflare_docker
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.auth0
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.huggingface
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.huggingface_co
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.huggingface_co_wildcard
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.xethub_hf_co
  lifecycle { destroy = false }
}
removed {
  from = azurerm_machine_learning_workspace_network_outbound_rule_fqdn.xethub_hf_co_wildcard
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
