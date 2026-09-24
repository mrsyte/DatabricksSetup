variable "prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "resource_group_name" {
  type = string
}

variable "hub_vnet_id" {
  type = string
}

variable "spoke_vnet_ids" {
  description = "Map of name → VNet ID for all spokes that need zone links"
  type        = map(string)
  default     = {}
}

variable "tags" {
  type = map(string)
}
