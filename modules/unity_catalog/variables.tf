variable "prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "location" {
  type = string
}

variable "metastore_storage_id" {
  description = "Azure storage container resource ID for the metastore root"
  type        = string
}

variable "metastore_access_connector_id" {
  description = "Access Connector ID for Unity Catalog metastore root storage"
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
    storage_account_id  = string
    adls_container_urls = map(string) # { dev = "abfss://...", test = "...", prod = "..." }
    connector_id        = string
    owners_group_id     = string
    engineers_group_id  = string
    viewers_group_id    = string
    catalog_comment     = string
    owner               = string
    teams_channel       = string
    workspace_number    = number
    subject_areas = list(object({
      name    = string
      comment = string
      owner   = string
    }))
  }))
}
