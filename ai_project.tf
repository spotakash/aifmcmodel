# =============================================================================
# AI Foundry Project — Project workspace linked to the Hub
#
# Uses azurerm_ai_foundry_project (native provider support).
# The online endpoint and HuggingFace model deployment are attached to
# this project.
# =============================================================================

# -----------------------------------------------------------------------------
# Purge any soft-deleted project with the same name before re-creating.
# -----------------------------------------------------------------------------
resource "terraform_data" "purge_soft_deleted_ai_project" {
  input = local.ai_project_name

  provisioner "local-exec" {
    command = "az rest --method DELETE --url 'https://management.azure.com/subscriptions/${data.azurerm_client_config.current.subscription_id}/resourceGroups/${local.resource_group_name}/providers/Microsoft.MachineLearningServices/workspaces/${local.ai_project_name}?api-version=2024-04-01&forceToPurge=true' 2>/dev/null || true; sleep 30"
  }

  depends_on = [azurerm_ai_foundry.ai_hub]
}

resource "azurerm_ai_foundry_project" "ai_project" {
  name               = local.ai_project_name
  location           = azurerm_ai_foundry.ai_hub.location
  ai_services_hub_id = azurerm_ai_foundry.ai_hub.id

  friendly_name = local.ai_project_name
  description   = "AI Foundry Project for ${var.project_name}"

  identity {
    type = "SystemAssigned"
  }

  tags = local.tags

  depends_on = [terraform_data.purge_soft_deleted_ai_project]

  # ---------------------------------------------------------------------------
  # Destroy-time provisioner: ensures all child online endpoints are fully
  # removed before Azure deletes the project. Covers two scenarios:
  # 1. Endpoints Terraform didn't delete (orphaned) — lists and deletes them
  # 2. Endpoints Terraform already deleted — Azure needs time to fully process
  #    the internal cleanup (eventual consistency), so we always wait 90s.
  # Without this, Azure returns 409 CannotDeleteResource.
  # ---------------------------------------------------------------------------
  provisioner "local-exec" {
    when    = destroy
    command = "bash -c 'endpoints=$(az rest --method GET --url \"https://management.azure.com${self.id}/onlineEndpoints?api-version=2025-01-01-preview\" --query \"value[].name\" -o tsv 2>&1 | grep -v \"^ERROR\" || true); for ep in $endpoints; do [ -z \"$ep\" ] && continue; echo \"Deleting online endpoint: $ep\"; az rest --method DELETE --url \"https://management.azure.com${self.id}/onlineEndpoints/$ep?api-version=2025-01-01-preview\" 2>/dev/null || true; echo \"Polling for $ep deletion (up to 6 min)...\"; for i in $(seq 1 36); do sleep 10; az rest --method GET --url \"https://management.azure.com${self.id}/onlineEndpoints/$ep?api-version=2025-01-01-preview\" 2>/dev/null || { echo \"Endpoint $ep deleted.\"; break; }; echo \"  still deleting $ep ($((i*10))s)...\"; done; done; echo \"Waiting 90s for Azure internal cleanup...\"; sleep 90; true'"
  }
}
