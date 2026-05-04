terraform {
  required_version = ">= 1.6"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
    }
  }

  # ===========================================================================
  # Remote State Backend — Azure Storage Account
  # ===========================================================================
  # State is stored in an Azure Blob Storage container. Backend values are
  # provided at init time via -backend-config flags (see GitHub Actions workflows)
  # or via a backend config file:
  #
  #   terraform init -backend-config=backend.tfvars
  #
  # Required backend.tfvars keys:
  #   resource_group_name  = "rg-terraform-state"
  #   storage_account_name = "stterraformstate"
  #   container_name       = "tfstate"
  #   key                  = "aifmcmodel.terraform.tfstate"
  #
  # Authentication uses Azure OIDC (ARM_USE_OIDC=true) — no storage keys needed.
  # ===========================================================================
  backend "azurerm" {
    use_oidc = true
  }
}
