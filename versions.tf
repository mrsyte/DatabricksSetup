terraform {
  required_version = ">= 1.6.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.53"
    }
    databricks = {
      source  = "databricks/databricks"
      version = "~> 1.52"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state – fill in before first apply
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstate" # override with -backend-config
    container_name       = "tfstate"
    key                  = "databricks-hub-spoke.tfstate"
  }
}

# Default provider targets the hub subscription
provider "azurerm" {
  subscription_id = var.hub_subscription_id
  features {
    key_vault {
      purge_soft_delete_on_destroy    = false
      recover_soft_deleted_key_vaults = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = true
    }
  }
}

# Account-level Databricks provider (Unity Catalog, group sync, metastore)
# All Databricks resources use this provider. Workspace-level config
# (cluster policies, workspace conf, secret scopes) is applied by
# scripts/workspace_bootstrap.py after terraform apply.
provider "databricks" {
  alias      = "account"
  host       = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
}
