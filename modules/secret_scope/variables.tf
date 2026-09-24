variable "scope_name" {
  description = "Name of the Databricks secret scope"
  type        = string
}

variable "keyvault_id" {
  description = "Azure resource ID of the Key Vault"
  type        = string
}

variable "keyvault_uri" {
  description = "URI of the Key Vault (e.g. https://kv-name.vault.azure.net/)"
  type        = string
}
