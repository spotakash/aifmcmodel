# =============================================================================
# Wait for AI Foundry Project internal services to initialize
# (managed endpoints, identity propagation, KV access policies)
# =============================================================================

resource "time_sleep" "wait_for_project" {
  depends_on      = [azurerm_ai_foundry_project.ai_project]
  create_duration = "120s"
}

# =============================================================================
# Managed Online Endpoint — hosted in the AI Foundry Project
#
# Uses azapi because azurerm does not fully support managed online endpoints
# with traffic routing and HuggingFace registry model deployments.
# =============================================================================

resource "azapi_resource" "online_endpoint" {
  type      = "Microsoft.MachineLearningServices/workspaces/onlineEndpoints@2025-01-01-preview"
  name      = local.endpoint_name
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_ai_foundry_project.ai_project.id

  depends_on = [time_sleep.wait_for_project]

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "Managed"
    properties = {
      authMode            = "Key"
      description         = "Online endpoint for ${var.project_name} model serving"
      publicNetworkAccess = local.public_network_access
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true

  timeouts {
    create = "30m"
    delete = "10m"
  }

  lifecycle {
    ignore_changes = [
      body.properties.traffic,
    ]
  }
}

# =============================================================================
# Managed Online Deployment — HuggingFace self-hosted model
#
# Deploys alibaba-nlp/gte-large-en-v1.5 (or any model from azureml registry)
# as a managed online deployment. The model is pulled from the HuggingFace
# registry in Azure ML and served on the specified VM instance type.
# =============================================================================

resource "azapi_resource" "model_deployment" {
  type      = "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/deployments@2025-01-01-preview"
  name      = var.deployment_name
  location  = azurerm_resource_group.main.location
  parent_id = azapi_resource.online_endpoint.id

  body = {
    kind = "Managed"
    properties = {
      description               = "Self-hosted HuggingFace model deployment"
      endpointComputeType       = "Managed"
      model                     = var.model_id
      instanceType              = local.resolved_instance_type
      appInsightsEnabled        = true

      requestSettings = {
        maxConcurrentRequestsPerInstance = 1
        maxQueueWait                     = "PT5S"
        requestTimeout                   = "PT90S"
      }

      scaleSettings = {
        scaleType = "Default"
      }
    }

    sku = {
      name     = "Default"
      tier     = "Standard"
      capacity = var.deployment_instance_count
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true

  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}
