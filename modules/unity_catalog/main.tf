terraform {
  required_providers {
    databricks = {
      source                = "databricks/databricks"
      configuration_aliases = [databricks.account]
    }
  }
}

# ---------------------------------------------------------------------------
# Derived locals
# ---------------------------------------------------------------------------
locals {
  environments = ["dev", "test", "prod"]

  # Flat list of {domain, env} pairs
  domain_env_pairs = flatten([
    for domain_name, domain_cfg in var.domains : [
      for env in local.environments : {
        key    = "${domain_name}__${env}"
        domain = domain_name
        env    = env
      }
    ]
  ])

  # Flat list of {domain, env, zone} triples for landing-zone schemas
  landing_zones = ["raw", "curated", "published"]

  domain_env_zone = flatten([
    for pair in local.domain_env_pairs : [
      for zone in local.landing_zones : {
        key    = "${pair.domain}__${pair.env}__${zone}"
        domain = pair.domain
        env    = pair.env
        zone   = zone
      }
    ]
  ])

  # Flat list of {domain, env, subject} triples for subject-area schemas
  domain_env_subject = flatten([
    for pair in local.domain_env_pairs : [
      for sa in var.domains[pair.domain].subject_areas : {
        key     = "${pair.domain}__${pair.env}__${sa.name}"
        domain  = pair.domain
        env     = pair.env
        name    = sa.name
        comment = sa.comment != "" ? sa.comment : "Subject area ${sa.name} (${pair.env})"
        owner   = sa.owner != "" ? sa.owner : var.domains[pair.domain].owner
      }
    ]
  ])
}

# ---------------------------------------------------------------------------
# Metastore (one per region – shared across all workspaces)
# ---------------------------------------------------------------------------
resource "databricks_metastore" "main" {
  provider      = databricks.account
  name          = "metastore-${var.prefix}"
  region        = var.location
  storage_root  = var.metastore_storage_id
  force_destroy = false
}

resource "databricks_metastore_data_access" "main" {
  provider     = databricks.account
  metastore_id = databricks_metastore.main.id
  name         = "metastore-storage-credential"
  is_default   = true

  azure_managed_identity {
    access_connector_id = var.metastore_access_connector_id
  }

  depends_on = [databricks_metastore_assignment.domain]
}

# Assign metastore to every domain workspace
resource "databricks_metastore_assignment" "domain" {
  provider     = databricks.account
  for_each     = var.domains
  metastore_id = databricks_metastore.main.id
  workspace_id = each.value.workspace_number
  # Default to prod catalog so accidental writes don't land in dev
  default_catalog_name = "${each.key}_prod"

  depends_on = [databricks_metastore.main]
}

# ---------------------------------------------------------------------------
# Sync Entra admin group as metastore admin
# ---------------------------------------------------------------------------
resource "databricks_group" "metastore_admins" {
  provider     = databricks.account
  display_name = "metastore-admins"
  external_id  = var.admins_group_id
}

# ---------------------------------------------------------------------------
# Per-domain Entra group sync (account-level)
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
# Storage credentials (one per domain – access connector covers all 3 envs)
# ---------------------------------------------------------------------------
resource "databricks_storage_credential" "domain" {
  provider     = databricks.account
  for_each     = var.domains
  metastore_id = databricks_metastore.main.id
  name         = "sc-${each.key}"

  azure_managed_identity {
    access_connector_id = each.value.connector_id
  }

  comment    = "Storage credential for domain ${each.key}"
  depends_on = [databricks_metastore_assignment.domain]
}

# ---------------------------------------------------------------------------
# External locations (one per domain per environment)
# ---------------------------------------------------------------------------
resource "databricks_external_location" "domain_env" {
  provider     = databricks.account
  for_each     = { for p in local.domain_env_pairs : p.key => p }
  metastore_id = databricks_metastore.main.id
  name         = "el-${each.value.domain}-${each.value.env}"
  url          = var.domains[each.value.domain].adls_container_urls[each.value.env]

  credential_name = databricks_storage_credential.domain[each.value.domain].name
  comment         = "External location for ${each.value.domain}/${each.value.env}"

  depends_on = [databricks_storage_credential.domain]
}

# ---------------------------------------------------------------------------
# Catalogs – one per domain per environment: {domain}_{env}
# ---------------------------------------------------------------------------
resource "databricks_catalog" "domain_env" {
  provider     = databricks.account
  for_each     = { for p in local.domain_env_pairs : p.key => p }
  metastore_id = databricks_metastore.main.id
  name         = "${each.value.domain}_${each.value.env}"
  storage_root = var.domains[each.value.domain].adls_container_urls[each.value.env]

  comment = coalesce(
    var.domains[each.value.domain].catalog_comment != "" ? "${var.domains[each.value.domain].catalog_comment} (${each.value.env})" : "",
    "Catalog for ${each.value.domain} domain – ${each.value.env} environment"
  )

  properties = {
    domain        = each.value.domain
    environment   = each.value.env
    owner         = var.domains[each.value.domain].owner
    teams_channel = var.domains[each.value.domain].teams_channel
    app           = "databricks-platform"
    managed       = "terraform"
  }

  depends_on = [databricks_external_location.domain_env, databricks_metastore_assignment.domain]
}

# ---------------------------------------------------------------------------
# Landing-zone schemas (raw / curated / published) per domain per env
# ---------------------------------------------------------------------------
resource "databricks_schema" "landing_zone" {
  provider     = databricks.account
  for_each     = { for t in local.domain_env_zone : t.key => t }
  metastore_id = databricks_metastore.main.id

  catalog_name = databricks_catalog.domain_env["${each.value.domain}__${each.value.env}"].name
  name         = each.value.zone
  comment      = "${each.value.zone} zone – ${each.value.domain}/${each.value.env}"

  properties = {
    domain      = each.value.domain
    environment = each.value.env
    zone        = each.value.zone
    owner       = var.domains[each.value.domain].owner
    app         = "databricks-platform"
    managed     = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Subject-area schemas per domain per env
# Flat key: "{domain}__{env}__{subject}"
# ---------------------------------------------------------------------------
resource "databricks_schema" "subject_area" {
  provider     = databricks.account
  for_each     = { for s in local.domain_env_subject : s.key => s }
  metastore_id = databricks_metastore.main.id

  catalog_name = databricks_catalog.domain_env["${each.value.domain}__${each.value.env}"].name
  name         = each.value.name
  comment      = each.value.comment

  properties = {
    domain      = each.value.domain
    environment = each.value.env
    subject     = each.value.name
    owner       = each.value.owner
    app         = "databricks-platform"
    managed     = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Grants – catalog level
# prod:  owners=ALL, engineers=USE+CREATE+WRITE, viewers=USE only
# dev/test: engineers=ALL for rapid iteration
# ---------------------------------------------------------------------------
resource "databricks_grants" "catalog" {
  provider = databricks.account
  for_each = { for p in local.domain_env_pairs : p.key => p }
  catalog  = databricks_catalog.domain_env[each.key].name

  grant {
    principal  = databricks_group.owners[each.value.domain].display_name
    privileges = ["ALL_PRIVILEGES"]
  }

  dynamic "grant" {
    for_each = each.value.env == "prod" ? [1] : []
    content {
      principal  = databricks_group.engineers[each.value.domain].display_name
      privileges = ["USE_CATALOG", "CREATE_SCHEMA", "CREATE_TABLE", "CREATE_FUNCTION"]
    }
  }

  dynamic "grant" {
    for_each = each.value.env != "prod" ? [1] : []
    content {
      principal  = databricks_group.engineers[each.value.domain].display_name
      privileges = ["ALL_PRIVILEGES"]
    }
  }

  grant {
    principal  = databricks_group.viewers[each.value.domain].display_name
    privileges = ["USE_CATALOG"]
  }
}

# Schema-level grants (landing zones)
resource "databricks_grants" "schema_landing" {
  provider = databricks.account
  for_each = { for t in local.domain_env_zone : t.key => t }
  schema   = "${databricks_catalog.domain_env["${each.value.domain}__${each.value.env}"].name}.${each.value.zone}"

  grant {
    principal  = databricks_group.engineers[each.value.domain].display_name
    privileges = ["ALL_PRIVILEGES"]
  }
  grant {
    principal  = databricks_group.viewers[each.value.domain].display_name
    privileges = ["USE_SCHEMA", "SELECT"]
  }
}

# External location grants
resource "databricks_grants" "external_location" {
  provider          = databricks.account
  for_each          = { for p in local.domain_env_pairs : p.key => p }
  external_location = databricks_external_location.domain_env[each.key].name

  grant {
    principal  = databricks_group.owners[each.value.domain].display_name
    privileges = ["ALL_PRIVILEGES"]
  }
  grant {
    principal  = databricks_group.engineers[each.value.domain].display_name
    privileges = ["READ_FILES", "WRITE_FILES"]
  }
}
