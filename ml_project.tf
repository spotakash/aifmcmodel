# =============================================================================
# AI Foundry Project — Project workspace linked to the Hub (kind = "Project")
#
# Uses azapi because AI Foundry Projects require hubResourceId which is
# not fully supported in azurerm. The online endpoint and HuggingFace
# model deployment are attached to this project.
# =============================================================================

resource "azapi_resource" "ai_project" {
  type      = "Microsoft.MachineLearningServices/workspaces@2025-01-01-preview"
  name      = local.ai_project_name
  location  = azurerm_resource_group.main.location
  parent_id = azurerm_resource_group.main.id

  tags = local.tags

  identity {
    type = "SystemAssigned"
  }

  body = {
    kind = "Project"
    sku = {
      name = "Basic"
      tier = "Basic"
    }
    properties = {
      friendlyName        = local.ai_project_name
      description         = "AI Foundry Project for ${var.project_name}"
      hubResourceId       = azapi_resource.ai_hub.id
      publicNetworkAccess = local.public_network_access
    }
  }

  schema_validation_enabled = false
  ignore_missing_property   = true

  # ---------------------------------------------------------------------------
  # Destroy-time provisioner: delete all child online endpoints (and their
  # deployments) before Terraform deletes the project. Without this, Azure
  # returns 409 CannotDeleteResource because nested resources still exist.
  # ---------------------------------------------------------------------------
  provisioner "local-exec" {
    when    = destroy
    command = "bash -c 'endpoints=$(az rest --method GET --url \"https://management.azure.com${self.id}/onlineEndpoints?api-version=2025-01-01-preview\" --query \"value[].name\" -o tsv 2>/dev/null || true); for ep in $endpoints; do [ -z \"$ep\" ] && continue; echo \"Deleting online endpoint: $ep\"; az rest --method DELETE --url \"https://management.azure.com${self.id}/onlineEndpoints/$ep?api-version=2025-01-01-preview\" 2>/dev/null || true; done; [ -n \"$endpoints\" ] && sleep 60; true'"
  }
}
