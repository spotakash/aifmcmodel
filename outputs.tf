# =============================================================================
# Outputs — Only the model scoring endpoint is displayed.
# All other resource IDs are available via terraform state show if needed.
# =============================================================================

output "scoring_endpoint" {
  description = "Model scoring endpoint URI"
  value       = try(azapi_resource.online_endpoint.output.properties.scoringUri, "https://${azapi_resource.online_endpoint.name}.${var.location}.inference.ml.azure.com/v1/embeddings")
}
