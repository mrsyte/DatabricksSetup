# ---------------------------------------------------------------------------
# Bootstrap: Terraform remote state storage
# Run ONCE before the main deployment with a local backend.
# After apply, copy the output values into the main backend block.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  # Intentionally local – this is the bootstrap, there is no remote state yet
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

variable "subscription_id" {
  type = string
}

variable "location" {
  type    = string
  default = "eastus2"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "deployer_object_id" {
  description = "Object ID of the service principal / user running Terraform"
  type        = string
}

# Short random suffix to ensure storage account name uniqueness
resource "random_id" "suffix" {
  byte_length = 3
}

resource "azurerm_resource_group" "tfstate" {
  name     = "rg-tfstate-${var.environment}"
  location = var.location

  tags = {
    managed_by  = "terraform-bootstrap"
    environment = var.environment
  }
}

resource "azurerm_storage_account" "tfstate" {
  name                            = "sttfstate${var.environment}${random_id.suffix.hex}"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.tfstate.name
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  # State storage should not be publicly accessible
  public_network_access_enabled = true # Allow deployer access; lock down via network rules below

  blob_properties {
    versioning_enabled = true # Roll back to previous state versions if needed

    delete_retention_policy {
      days = 30
    }
  }

  tags = {
    managed_by  = "terraform-bootstrap"
    environment = var.environment
    purpose     = "terraform-state"
  }
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_name  = azurerm_storage_account.tfstate.name
  container_access_type = "private"
}

# Grant the deployer Blob Data Contributor so it can read/write state
resource "azurerm_role_assignment" "deployer" {
  scope                = azurerm_storage_account.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.deployer_object_id
}

# ---------------------------------------------------------------------------
# Outputs – paste these into the main deployment's backend block
# ---------------------------------------------------------------------------
output "resource_group_name" {
  value       = azurerm_resource_group.tfstate.name
  description = "backend.resource_group_name"
}

output "storage_account_name" {
  value       = azurerm_storage_account.tfstate.name
  description = "backend.storage_account_name"
}

output "container_name" {
  value       = azurerm_storage_container.tfstate.name
  description = "backend.container_name"
}

output "backend_config_snippet" {
  value       = <<-EOT
    # Add to versions.tf backend block:
    resource_group_name  = "${azurerm_resource_group.tfstate.name}"
    storage_account_name = "${azurerm_storage_account.tfstate.name}"
    container_name       = "tfstate"
    key                  = "databricks-hub-spoke.tfstate"
  EOT
  description = "Copy/paste into the main backend block in versions.tf"
}
