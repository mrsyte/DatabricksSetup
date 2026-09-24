variable "prefix" {
  type = string
}

variable "location" {
  type = string
}

variable "address_space" {
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

variable "tags" {
  type = map(string)
}
