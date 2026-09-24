variable "prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "location" {
  type = string
}

variable "workspace_id" {
  description = "Azure resource ID of the Databricks workspace"
  type        = string
}

variable "workspace_number" {
  description = "Numeric workspace ID (azurerm_databricks_workspace.workspace_id)"
  type        = number
}

variable "metastore_storage_id" {
  description = "Azure storage container resource ID for the metastore root"
  type        = string
}

variable "tenant_id" {
  type = string
}

variable "admins_group_id" {
  description = "Object ID of the Entra group to assign as metastore admin"
  type        = string
}

variable "domains" {
  description = "Per-domain Unity Catalog configuration"
  type = map(object({
    storage_account_id    = string
    storage_container_url = string
    connector_id          = string
    owners_group_id       = string
    engineers_group_id    = string
    viewers_group_id      = string
    catalog_comment       = string
    owner                 = string
    subject_areas = list(object({
      name    = string
      comment = string
      owner   = string
    }))
  }))
}
