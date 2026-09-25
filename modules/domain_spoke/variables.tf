variable "domain_name" {
  type = string
}

variable "domain_owner" {
  description = "Team/contact owning this domain – applied as owner tag"
  type        = string
  default     = ""
}

variable "prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "hub_vnet_id" {
  type = string
}

variable "hub_vnet_rg" {
  type = string
}

variable "firewall_private_ip" {
  type = string
}

variable "dns_resource_group_name" {
  description = "Resource group containing the shared private DNS zones"
  type        = string
}

variable "pe_dns_zone_adb_id" {
  description = "Private DNS zone ID for privatelink.azuredatabricks.net"
  type        = string
}

variable "pe_dns_zone_blob_id" {
  type = string
}

variable "pe_dns_zone_dfs_id" {
  type = string
}

variable "pe_dns_zone_kv_id" {
  type = string
}

variable "log_analytics_id" {
  type = string
}

variable "tags" {
  type = map(string)
}
