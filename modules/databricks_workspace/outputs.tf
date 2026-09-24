output "workspace_url" {
  value = "https://${azurerm_databricks_workspace.main.workspace_url}"
}

output "workspace_id" {
  description = "Azure resource ID of the workspace"
  value       = azurerm_databricks_workspace.main.id
}

output "workspace_number" {
  description = "Numeric workspace ID (used for metastore assignment)"
  value       = azurerm_databricks_workspace.main.workspace_id
}

output "managed_identity_principal_id" {
  description = "Object ID of the workspace managed identity"
  value       = azurerm_databricks_workspace.main.storage_account_identity[0].principal_id
}

output "managed_identity_tenant_id" {
  value = azurerm_databricks_workspace.main.storage_account_identity[0].tenant_id
}

output "resource_group_name" {
  value = azurerm_resource_group.adb_ws.name
}
