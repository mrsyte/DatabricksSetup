variable "prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "location" {
  type = string
}

variable "hub_resource_group_name" {
  type = string
}

variable "adb_vnet_id" {
  type = string
}

variable "adb_vnet_rg" {
  type = string
}

variable "public_subnet_name" {
  type = string
}

variable "private_subnet_name" {
  type = string
}

variable "public_subnet_nsg_id" {
  type = string
}

variable "private_subnet_nsg_id" {
  type = string
}

variable "pe_subnet_id" {
  description = "Subnet ID for private endpoints"
  type        = string
}

variable "hub_vnet_id" {
  type = string
}

variable "private_dns_zone_id" {
  description = "Private DNS zone ID for privatelink.azuredatabricks.net"
  type        = string
}

variable "log_analytics_id" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "default_cluster_tags" {
  description = "Custom tags applied to every cluster via the default cluster policy"
  type        = map(string)
  default     = {}
}

variable "tags" {
  type = map(string)
}
