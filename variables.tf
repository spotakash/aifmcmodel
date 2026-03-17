# =============================================================================
# General
# =============================================================================

variable "location" {
  description = "Azure region for all resources"
  type        = string
  default     = "australiaeast"
}

variable "project_name" {
  description = "Short project name used as naming prefix for all resources (3-12 chars, lowercase alphanumeric)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,12}$", var.project_name))
    error_message = "project_name must be 3-12 lowercase alphanumeric characters (e.g. 'rehub', '1503ak')."
  }
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Extra tags merged with defaults"
  type        = map(string)
  default     = {}
}

# =============================================================================
# Networking
# =============================================================================

variable "public_network_access" {
  description = "Enable public network access on all resources (true = Enabled, false = Disabled)"
  type        = bool
  default     = true
}

# =============================================================================
# Online Endpoint & Deployment (HuggingFace Model)
# =============================================================================

variable "deployment_name" {
  description = "Name of the model deployment (3-32 chars, alphanumeric and dashes)"
  type        = string

  validation {
    condition     = length(var.deployment_name) >= 3 && length(var.deployment_name) <= 32
    error_message = "deployment_name must be 3-32 characters."
  }
}

variable "model_id" {
  description = "Full model URI from Azure ML registry"
  type        = string
}

variable "deployment_instance_type" {
  description = "VM instance type for the model deployment"
  type        = string
  default     = "Standard_DS5_v2"
}

variable "deployment_instance_count" {
  description = "Number of instances for the model deployment"
  type        = number
  default     = 1
}
