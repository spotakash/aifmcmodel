# =============================================================================
# Provider Configuration
# =============================================================================
# Authentication: Azure OIDC via Entra ID federated credentials.
# When running in GitHub Actions, set these environment variables:
#   ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID, ARM_USE_OIDC=true
#
# For local development, use `az login` — the provider will auto-detect credentials.
# =============================================================================

provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  # OIDC auth fields are read from ARM_* environment variables automatically.
  # No hardcoded credentials here.
}

provider "azapi" {}

