variable "prefix" {
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

variable "vpn_client_pool" {
  type = list(string)
}

variable "vpn_aad_audience" {
  type = string
}

variable "log_analytics_id" {
  description = "Self-referencing – pass module output back in (use null on first apply, then the real ID)"
  type        = string
  default     = null
}

variable "tags" {
  type = map(string)
}
