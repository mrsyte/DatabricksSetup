terraform {
  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}

# Key Vault–backed secret scope
# All secrets stored in the linked Key Vault are accessible via
# dbutils.secrets.get(scope="<scope_name>", key="<kv-secret-name>")
resource "databricks_secret_scope" "kv_backed" {
  name = var.scope_name

  keyvault_metadata {
    resource_id = var.keyvault_id
    dns_name    = var.keyvault_uri
  }
}
