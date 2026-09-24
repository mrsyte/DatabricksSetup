output "metastore_id" {
  value = databricks_metastore.main.id
}

output "catalog_names" {
  value = { for k, v in databricks_catalog.domain : k => v.name }
}

output "external_location_names" {
  value = { for k, v in databricks_external_location.domain : k => v.name }
}
