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

output "adls_container_urls" {
  description = "Map of environment → abfss container URL for Unity Catalog external locations"
  value = {
    for env in ["dev", "test", "prod"] :
    env => "abfss://${env}@${azurerm_storage_account.domain.name}.dfs.core.windows.net/"
  }
  depends_on = [azurerm_storage_container.env]
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

output "workspace_url" {
  description = "HTTPS URL of the domain Databricks workspace"
  value       = "https://${azurerm_databricks_workspace.domain.workspace_url}"
}

output "workspace_id" {
  description = "Azure resource ID of the domain workspace"
  value       = azurerm_databricks_workspace.domain.id
}

output "workspace_number" {
  description = "Numeric workspace ID – used for Unity Catalog metastore assignment"
  value       = azurerm_databricks_workspace.domain.workspace_id
}

output "workspace_principal_id" {
  description = "Object ID of the workspace system-assigned managed identity"
  value       = azurerm_databricks_workspace.domain.storage_account_identity[0].principal_id
}
