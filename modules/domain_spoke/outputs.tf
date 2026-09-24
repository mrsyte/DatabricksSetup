output "vnet_id" {
  value = azurerm_virtual_network.spoke.id
}

output "resource_group_name" {
  value = azurerm_resource_group.spoke.name
}

output "storage_account_id" {
  value = azurerm_storage_account.domain.id
}

output "storage_account_name" {
  value = azurerm_storage_account.domain.name
}

output "adls_container_url" {
  value = "abfss://data@${azurerm_storage_account.domain.name}.dfs.core.windows.net/"
}

output "access_connector_id" {
  value = azurerm_databricks_access_connector.domain.id
}

output "keyvault_id" {
  value = azurerm_key_vault.domain.id
}

output "keyvault_uri" {
  value = azurerm_key_vault.domain.vault_uri
}

output "keyvault_name" {
  value = azurerm_key_vault.domain.name
}

output "pe_subnet_id" {
  value = azurerm_subnet.pe.id
}
