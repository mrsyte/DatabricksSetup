# ---------------------------------------------------------------------------
# Azure Subscription creation
#
# Prerequisites:
#   - EA (Enterprise Agreement) enrollment OR Microsoft Customer Agreement (MCA)
#   - The deploying identity must have the "Enrollment Account Owner" role
#     on the EA enrollment, or "Azure Subscription Creator" on the MCA billing scope
#
# Run ONCE per environment, BEFORE the main Terraform deployment.
# After the subscription exists, record its ID and set it in terraform.tfvars.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.116"
    }
  }
}

provider "azurerm" {
  features {}
  # Use a service principal with subscription-creation rights
  # Set via ARM_* environment variables or a backend config file
}

# ──────────────────────────────────────────────────────────────────────────────
# Variables
# ──────────────────────────────────────────────────────────────────────────────
variable "environment" {
  type    = string
  default = "prod"
}

variable "billing_account_name" {
  description = <<-EOT
    For EA: the enrollment account name (a GUID-like string).
      az billing enrollment-account list --query "[].name" -o tsv
    For MCA: the billing profile / invoice section name.
  EOT
  type = string
}

variable "billing_scope" {
  description = <<-EOT
    Full billing scope resource ID. Examples:
      EA:  /providers/Microsoft.Billing/billingAccounts/<EA_ENROLLMENT>/enrollmentAccounts/<ACCOUNT>
      MCA: /providers/Microsoft.Billing/billingAccounts/<BILLING_ACCOUNT>/billingProfiles/<PROFILE>/invoiceSections/<SECTION>
    Retrieve with:
      az billing account list
      az billing enrollment-account list
  EOT
  type = string
}

variable "management_group_id" {
  description = "Management group to place the new subscription under (optional)"
  type        = string
  default     = null
}

variable "additional_owners" {
  description = "List of principal object IDs to assign Owner on the new subscription"
  type        = list(string)
  default     = []
}

# ──────────────────────────────────────────────────────────────────────────────
# Hub subscription
# ──────────────────────────────────────────────────────────────────────────────
resource "azurerm_subscription" "hub" {
  subscription_name = "sub-databricks-hub-${var.environment}"
  billing_scope_id  = var.billing_scope

  tags = {
    environment = var.environment
    managed_by  = "terraform"
    purpose     = "databricks-hub-shared-services"
  }
}

# Place under management group (if provided)
resource "azurerm_management_group_subscription_association" "hub" {
  count               = var.management_group_id != null ? 1 : 0
  management_group_id = var.management_group_id
  subscription_id     = azurerm_subscription.hub.subscription_id
}

# Grant additional owners (e.g. the Terraform SP)
resource "azurerm_role_assignment" "hub_owner" {
  for_each = toset(var.additional_owners)

  scope                = "/subscriptions/${azurerm_subscription.hub.subscription_id}"
  role_definition_name = "Owner"
  principal_id         = each.value
}

# ──────────────────────────────────────────────────────────────────────────────
# Outputs – paste into the main terraform.tfvars
# ──────────────────────────────────────────────────────────────────────────────
output "hub_subscription_id" {
  value       = azurerm_subscription.hub.subscription_id
  description = "Set as hub_subscription_id in the main terraform.tfvars"
}

output "subscription_setup_snippet" {
  value = <<-EOT
    # Paste into terraform.tfvars:
    hub_subscription_id = "${azurerm_subscription.hub.subscription_id}"
  EOT
}
