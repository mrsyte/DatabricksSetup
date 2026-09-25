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

output "metastore_id" {
  description = "Unity Catalog metastore ID"
  value       = module.unity_catalog.metastore_id
}

output "domain_workspace_urls" {
  description = "Databricks workspace URL per domain – used by workspace_bootstrap.py"
  value       = { for k, v in module.domain_spoke : k => v.workspace_url }
}

output "domain_workspace_ids" {
  description = "Azure resource ID per domain workspace"
  value       = { for k, v in module.domain_spoke : k => v.workspace_id }
}

output "domain_catalog_names" {
  description = "Catalog names per domain/environment – key is '{domain}__{env}'"
  value       = module.unity_catalog.catalog_names
}

output "domain_storage_accounts" {
  description = "Storage account name per domain"
  value       = { for k, v in module.domain_spoke : k => v.storage_account_name }
}

output "domain_keyvault_uris" {
  description = "Key Vault URI per domain"
  value       = { for k, v in module.domain_spoke : k => v.keyvault_uri }
  sensitive   = true
}
