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
  tags      = local.tags

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

# =============================================================================
# Traffic Allocation — Route 100% traffic to the deployment
#
# Azure does not automatically route traffic to a new deployment. This
# explicitly sets the endpoint traffic map after the deployment succeeds.
# Uses azapi_update_resource to PATCH the endpoint with the traffic rule.
# =============================================================================

resource "azapi_update_resource" "endpoint_traffic" {
  type        = "Microsoft.MachineLearningServices/workspaces/onlineEndpoints@2025-01-01-preview"
  resource_id = azapi_resource.online_endpoint.id

  body = {
    properties = {
      traffic = {
        (azapi_resource.model_deployment.name) = 100
      }
    }
  }

  depends_on = [azapi_resource.model_deployment]
}

# =============================================================================
# Destroy-time Traffic Zeroing — Azure blocks deletion of deployments that
# have non-zero traffic weight. This provisioner zeros the traffic map on
# the endpoint before Terraform attempts to delete the deployment.
#
# Uses single-line command (WSL/CRLF safety — no heredocs on /mnt/c/).
# The PUT replaces the entire endpoint — location + identity + kind are
# required fields even when only changing traffic.
# =============================================================================

resource "terraform_data" "zero_endpoint_traffic" {
  input = {
    endpoint_id = azapi_resource.online_endpoint.id
    location    = azurerm_resource_group.main.location
  }

  depends_on = [azapi_update_resource.endpoint_traffic]

  provisioner "local-exec" {
    when    = destroy
    command = "az rest --method PUT --url 'https://management.azure.com${self.input.endpoint_id}?api-version=2025-01-01-preview' --body '{\"location\":\"${self.input.location}\",\"identity\":{\"type\":\"SystemAssigned\"},\"kind\":\"Managed\",\"properties\":{\"authMode\":\"Key\",\"traffic\":{}}}' 2>/dev/null || true; echo 'Traffic zeroed, waiting 30s...'; sleep 30"
  }
}
