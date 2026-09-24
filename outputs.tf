output "workspace_url" {
  description = "Databricks workspace URL"
  value       = module.databricks_workspace.workspace_url
}

output "workspace_id" {
  description = "Databricks workspace Azure resource ID"
  value       = module.databricks_workspace.workspace_id
}

output "hub_vnet_id" {
  description = "Hub VNet resource ID"
  value       = module.hub_network.hub_vnet_id
}

output "vpn_gateway_ip" {
  description = "VPN Gateway public IP – configure in VPN client profiles"
  value       = module.hub_network.vpn_gateway_public_ip
}

output "log_analytics_workspace_id" {
  description = "Log Analytics workspace ID for diagnostics"
  value       = module.hub_network.log_analytics_id
}

output "domain_catalog_names" {
  description = "Unity Catalog catalog name per domain"
  value       = module.unity_catalog.catalog_names
}

output "domain_storage_accounts" {
  description = "Storage account names per domain"
  value = {
    for k, v in module.domain_spoke : k => v.storage_account_name
  }
}

output "domain_keyvault_uris" {
  description = "Key Vault URI per domain"
  value = {
    for k, v in module.domain_spoke : k => v.keyvault_uri
  }
  sensitive = true
}
