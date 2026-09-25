# ---------------------------------------------------------------------------
# Global
# ---------------------------------------------------------------------------
variable "environment" {
  description = "Deployment environment (dev, uat, prod)"
  type        = string

  validation {
    condition     = contains(["dev", "uat", "prod"], var.environment)
    error_message = "environment must be dev, uat, or prod."
  }
}

variable "location" {
  description = "Primary Azure region"
  type        = string
  default     = "centralus"
}

# ---------------------------------------------------------------------------
# Tagging
# ---------------------------------------------------------------------------
variable "app_name" {
  description = "Application name tag applied to all resources"
  type        = string
  default     = "databricks-platform"
}

variable "owner" {
  description = "Team or person responsible for the platform"
  type        = string
  default     = "data-platform-team"
}

variable "cost_center" {
  description = "Cost center / billing code"
  type        = string
  default     = "data-platform"
}

variable "tags" {
  description = "Additional tags merged onto all resources (override or extend computed tags)"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Subscriptions
# ---------------------------------------------------------------------------
variable "hub_subscription_id" {
  description = "Azure subscription ID for hub shared services"
  type        = string
}

# ---------------------------------------------------------------------------
# Entra / Azure AD
# ---------------------------------------------------------------------------
variable "tenant_id" {
  description = "Azure AD tenant ID"
  type        = string
}

# ---------------------------------------------------------------------------
# Databricks
# ---------------------------------------------------------------------------
variable "databricks_account_id" {
  description = "Databricks account ID (found in accounts.azuredatabricks.net)"
  type        = string
  sensitive   = true
}

variable "databricks_admins_group_object_id" {
  description = "Object ID of the Entra group that will be workspace admins"
  type        = string
}

variable "databricks_admin_sp_client_id" {
  description = "Client ID of the Terraform service principal granted Databricks account admin. Used as the initial account administrator."
  type        = string
  sensitive   = true
}

variable "databricks_admin_sp_object_id" {
  description = "Object ID of the Terraform service principal in Azure AD (needed for Key Vault + storage RBAC)"
  type        = string
}

# ---------------------------------------------------------------------------
# Hub network
# ---------------------------------------------------------------------------
variable "hub_vnet_address_space" {
  description = "CIDR for the hub VNet"
  type        = string
  default     = "10.0.0.0/16"
}

variable "vpn_client_address_pool" {
  description = "Address pool assigned to VPN clients"
  type        = list(string)
  default     = ["172.16.0.0/22"]
}

variable "vpn_aad_audience" {
  description = "Azure VPN AAD application audience (Azure VPN client)"
  type        = string
  default     = "41b23e61-6c1e-4545-b367-cd054e0ed4b4" # Azure Public VPN client
}

# ---------------------------------------------------------------------------
# Databricks workspace VNet (adb spoke)
# ---------------------------------------------------------------------------
variable "adb_vnet_address_space" {
  description = "CIDR for the Databricks workspace VNet (spoke)"
  type        = string
  default     = "10.1.0.0/16"
}

# ---------------------------------------------------------------------------
# Domains (OVERRIDE ONLY)
# ---------------------------------------------------------------------------
# The primary domain registry is domains.yaml. Set this variable only when
# you need to override or add domains via CLI/automation without editing the
# YAML (e.g. ephemeral CI environments, emergency patches).
# Any key present here is merged on top of the YAML; YAML keys not present
# here are kept as-is. To use only the YAML, leave this unset (null).
variable "domains" {
  description = "Override map for domains. Null means use domains.yaml exclusively."

  default  = null
  nullable = true

  type = map(object({
    address_space      = string
    owner              = optional(string, "")
    teams_channel      = optional(string, "")
    owners_group_id    = string
    engineers_group_id = string
    viewers_group_id   = string
    catalog_comment    = optional(string, "")
    subject_areas = optional(list(object({
      name    = string
      comment = optional(string, "")
      owner   = optional(string, "")
    })), [])
  }))

  validation {
    condition     = var.domains == null || length(var.domains) > 0
    error_message = "If domains override is set it must contain at least one entry."
  }
}
