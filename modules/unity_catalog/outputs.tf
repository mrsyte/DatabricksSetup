output "metastore_id" {
  value = databricks_metastore.main.id
}

output "catalog_names" {
  description = "Map of '{domain}__{env}' → catalog name"
  value       = { for k, v in databricks_catalog.domain_env : k => v.name }
}

output "external_location_names" {
  description = "Map of '{domain}__{env}' → external location name"
  value       = { for k, v in databricks_external_location.domain_env : k => v.name }
}
