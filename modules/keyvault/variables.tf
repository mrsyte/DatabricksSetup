variable "prefix" {
  type = string
}

variable "suffix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "tenant_id" {
  type = string
}

variable "pe_subnet_id" {
  type = string
}

variable "private_dns_zone_id" {
  type = string
}

variable "log_analytics_id" {
  type = string
}

variable "reader_principal_ids" {
  description = "Principal IDs to grant Key Vault Secrets User role"
  type        = list(string)
  default     = []
}

variable "tags" {
  type = map(string)
}
