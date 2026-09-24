terraform {
  required_providers {
    databricks = {
      source                = "databricks/databricks"
      configuration_aliases = [databricks.account, databricks.workspace]
    }
  }
}

# ---------------------------------------------------------------------------
# Metastore (one per region – shared across all workspaces in this region)
# ---------------------------------------------------------------------------
resource "databricks_metastore" "main" {
  provider      = databricks.account
  name          = "metastore-${var.prefix}"
  region        = var.location
  storage_root  = var.metastore_storage_id
  force_destroy = false
}

resource "databricks_metastore_assignment" "main" {
  provider             = databricks.account
  metastore_id         = databricks_metastore.main.id
  workspace_id         = var.workspace_number
  default_catalog_name = "hive_metastore"
}

# ---------------------------------------------------------------------------
# Sync Entra admin group as metastore admin
# ---------------------------------------------------------------------------
resource "databricks_group" "metastore_admins" {
  provider     = databricks.account
  display_name = "metastore-admins"
  external_id  = var.admins_group_id
}

resource "databricks_metastore_data_access" "main" {
  provider     = databricks.workspace
  metastore_id = databricks_metastore.main.id
  name         = "metastore-storage-credential"
  is_default   = true

  depends_on = [databricks_metastore_assignment.main]
}

# ---------------------------------------------------------------------------
# Per-domain: storage credential → external location → catalog → schemas
# ---------------------------------------------------------------------------

resource "databricks_storage_credential" "domain" {
  provider = databricks.workspace
  for_each = var.domains
  name     = "sc-${each.key}"

  azure_managed_identity {
    access_connector_id = each.value.connector_id
  }

  comment    = "Storage credential for domain ${each.key}"
  depends_on = [databricks_metastore_assignment.main]
}

resource "databricks_external_location" "domain" {
  provider        = databricks.workspace
  for_each        = var.domains
  name            = "el-${each.key}"
  url             = each.value.storage_container_url
  credential_name = databricks_storage_credential.domain[each.key].name
  comment         = "External location for domain ${each.key}"

  depends_on = [databricks_storage_credential.domain]
}

# Catalogs – properties act as Unity Catalog–level tags
resource "databricks_catalog" "domain" {
  provider = databricks.workspace
  for_each = var.domains
  name     = each.key
  comment  = each.value.catalog_comment != "" ? each.value.catalog_comment : "Catalog for ${each.key} domain"

  storage_root = each.value.storage_container_url

  properties = {
    domain  = each.key
    owner   = each.value.owner
    app     = "databricks-platform"
    managed = "terraform"
  }

  depends_on = [databricks_external_location.domain, databricks_metastore_assignment.main]
}

# Landing-zone schemas (always created per domain)
resource "databricks_schema" "raw" {
  provider     = databricks.workspace
  for_each     = var.domains
  catalog_name = databricks_catalog.domain[each.key].name
  name         = "raw"
  comment      = "Raw ingestion zone"

  properties = {
    domain = each.key
    zone   = "raw"
    owner  = each.value.owner
    app    = "databricks-platform"
  }
}

resource "databricks_schema" "curated" {
  provider     = databricks.workspace
  for_each     = var.domains
  catalog_name = databricks_catalog.domain[each.key].name
  name         = "curated"
  comment      = "Curated / silver zone"

  properties = {
    domain = each.key
    zone   = "curated"
    owner  = each.value.owner
    app    = "databricks-platform"
  }
}

resource "databricks_schema" "published" {
  provider     = databricks.workspace
  for_each     = var.domains
  catalog_name = databricks_catalog.domain[each.key].name
  name         = "published"
  comment      = "Published / gold zone"

  properties = {
    domain = each.key
    zone   = "published"
    owner  = each.value.owner
    app    = "databricks-platform"
  }
}

# Subject-area schemas (one per entry in domain.subject_areas)
# Flat key: "<domain>__<subject_name>"
resource "databricks_schema" "subject_area" {
  provider = databricks.workspace

  for_each = {
    for pair in flatten([
      for domain_name, domain_cfg in var.domains : [
        for sa in domain_cfg.subject_areas : {
          key     = "${domain_name}__${sa.name}"
          domain  = domain_name
          name    = sa.name
          comment = sa.comment != "" ? sa.comment : "Subject area ${sa.name} in domain ${domain_name}"
          owner   = sa.owner != "" ? sa.owner : domain_cfg.owner
        }
      ]
    ]) : pair.key => pair
  }

  catalog_name = databricks_catalog.domain[each.value.domain].name
  name         = each.value.name
  comment      = each.value.comment

  properties = {
    domain   = each.value.domain
    subject  = each.value.name
    owner    = each.value.owner
    app      = "databricks-platform"
    managed  = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Entra group synchronisation (account-level)
# ---------------------------------------------------------------------------
resource "databricks_group" "owners" {
  provider     = databricks.account
  for_each     = var.domains
  display_name = "${each.key}-owners"
  external_id  = each.value.owners_group_id
}

resource "databricks_group" "engineers" {
  provider     = databricks.account
  for_each     = var.domains
  display_name = "${each.key}-engineers"
  external_id  = each.value.engineers_group_id
}

resource "databricks_group" "viewers" {
  provider     = databricks.account
  for_each     = var.domains
  display_name = "${each.key}-viewers"
  external_id  = each.value.viewers_group_id
}

# ---------------------------------------------------------------------------
# Grants
# ---------------------------------------------------------------------------
resource "databricks_grants" "catalog" {
  provider = databricks.workspace
  for_each = var.domains
  catalog  = databricks_catalog.domain[each.key].name

  grant {
    principal  = databricks_group.owners[each.key].display_name
    privileges = ["ALL_PRIVILEGES"]
  }
  grant {
    principal  = databricks_group.engineers[each.key].display_name
    privileges = ["USE_CATALOG", "CREATE_SCHEMA", "CREATE_TABLE", "CREATE_FUNCTION"]
  }
  grant {
    principal  = databricks_group.viewers[each.key].display_name
    privileges = ["USE_CATALOG"]
  }
}

resource "databricks_grants" "schema_raw" {
  provider = databricks.workspace
  for_each = var.domains
  schema   = "${databricks_catalog.domain[each.key].name}.raw"

  grant {
    principal  = databricks_group.engineers[each.key].display_name
    privileges = ["ALL_PRIVILEGES"]
  }
  grant {
    principal  = databricks_group.viewers[each.key].display_name
    privileges = ["USE_SCHEMA", "SELECT"]
  }
}

resource "databricks_grants" "schema_curated" {
  provider = databricks.workspace
  for_each = var.domains
  schema   = "${databricks_catalog.domain[each.key].name}.curated"

  grant {
    principal  = databricks_group.engineers[each.key].display_name
    privileges = ["ALL_PRIVILEGES"]
  }
  grant {
    principal  = databricks_group.viewers[each.key].display_name
    privileges = ["USE_SCHEMA", "SELECT"]
  }
}

resource "databricks_grants" "schema_published" {
  provider = databricks.workspace
  for_each = var.domains
  schema   = "${databricks_catalog.domain[each.key].name}.published"

  grant {
    principal  = databricks_group.engineers[each.key].display_name
    privileges = ["ALL_PRIVILEGES"]
  }
  grant {
    principal  = databricks_group.viewers[each.key].display_name
    privileges = ["USE_SCHEMA", "SELECT"]
  }
}

resource "databricks_grants" "external_location" {
  provider          = databricks.workspace
  for_each          = var.domains
  external_location = databricks_external_location.domain[each.key].name

  grant {
    principal  = databricks_group.owners[each.key].display_name
    privileges = ["ALL_PRIVILEGES"]
  }
  grant {
    principal  = databricks_group.engineers[each.key].display_name
    privileges = ["READ_FILES", "WRITE_FILES"]
  }
}
