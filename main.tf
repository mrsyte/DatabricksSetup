data "azurerm_client_config" "current" {}

# ---------------------------------------------------------------------------
# Random suffix for globally-unique names
# ---------------------------------------------------------------------------
resource "random_id" "suffix" {
  byte_length = 3
}

# ---------------------------------------------------------------------------
# Hub – shared services (Firewall, VPN Gateway, DNS Private Resolver)
# ---------------------------------------------------------------------------
module "hub_network" {
  source = "./modules/hub_network"

  prefix           = local.prefix
  location         = var.location
  address_space    = var.hub_vnet_address_space
  tenant_id        = var.tenant_id
  vpn_client_pool  = var.vpn_client_address_pool
  vpn_aad_audience = var.vpn_aad_audience
  log_analytics_id = null # Bootstrapped on first apply; set to module output on subsequent applies
  tags             = merge(local.common_tags, { component = "hub-network" })
}

# ---------------------------------------------------------------------------
# Central Private DNS (hub-hosted, linked to all VNets)
# ---------------------------------------------------------------------------
module "central_dns" {
  source = "./modules/central_dns"

  prefix              = local.prefix
  location            = var.location
  resource_group_name = module.hub_network.dns_resource_group_name
  hub_vnet_id         = module.hub_network.hub_vnet_id
  tags                = merge(local.common_tags, { component = "dns" })

  spoke_vnet_ids = merge(
    { adb = module.adb_vnet.vnet_id },
    { for k, v in module.domain_spoke : k => v.vnet_id }
  )

  depends_on = [module.hub_network]
}

# ---------------------------------------------------------------------------
# Databricks VNet (ADB spoke – VNet injection)
# ---------------------------------------------------------------------------
module "adb_vnet" {
  source = "./modules/adb_vnet"

  prefix              = local.prefix
  location            = var.location
  address_space       = var.adb_vnet_address_space
  hub_vnet_id         = module.hub_network.hub_vnet_id
  hub_vnet_rg         = module.hub_network.hub_resource_group_name
  firewall_private_ip = module.hub_network.firewall_private_ip
  tags                = merge(local.common_tags, { component = "adb-network" })

  depends_on = [module.hub_network]
}

# ---------------------------------------------------------------------------
# Databricks Workspace (single workspace shared by all domains)
# ---------------------------------------------------------------------------
module "databricks_workspace" {
  source = "./modules/databricks_workspace"

  prefix                  = local.prefix
  suffix                  = random_id.suffix.hex
  location                = var.location
  hub_resource_group_name = module.hub_network.hub_resource_group_name
  adb_vnet_id             = module.adb_vnet.vnet_id
  adb_vnet_rg             = module.adb_vnet.resource_group_name
  public_subnet_name      = module.adb_vnet.public_subnet_name
  private_subnet_name     = module.adb_vnet.private_subnet_name
  public_subnet_nsg_id    = module.adb_vnet.public_subnet_nsg_id
  private_subnet_nsg_id   = module.adb_vnet.private_subnet_nsg_id
  pe_subnet_id            = module.adb_vnet.pe_subnet_id
  hub_vnet_id             = module.hub_network.hub_vnet_id
  private_dns_zone_id     = module.central_dns.zone_ids["adb"]
  log_analytics_id        = module.hub_network.log_analytics_id
  tenant_id               = var.tenant_id
  default_cluster_tags    = local.databricks_default_cluster_tags
  tags                    = merge(local.common_tags, { component = "databricks-workspace" })

  depends_on = [module.adb_vnet, module.central_dns]
}

# ---------------------------------------------------------------------------
# Hub Key Vault (workspace-level shared secrets / infra)
# ---------------------------------------------------------------------------
module "hub_keyvault" {
  source = "./modules/keyvault"

  prefix              = local.prefix
  suffix              = "${random_id.suffix.hex}h"
  location            = var.location
  resource_group_name = module.hub_network.hub_resource_group_name
  tenant_id           = var.tenant_id
  pe_subnet_id        = module.adb_vnet.pe_subnet_id
  private_dns_zone_id = module.central_dns.zone_ids["keyvault"]
  log_analytics_id    = module.hub_network.log_analytics_id

  reader_principal_ids = [
    module.databricks_workspace.managed_identity_principal_id,
    var.databricks_admin_sp_object_id,
  ]
  tags = merge(local.common_tags, { component = "hub-keyvault" })

  depends_on = [module.central_dns]
}

# ---------------------------------------------------------------------------
# Per-domain spoke VNets + storage + domain Key Vaults
# ---------------------------------------------------------------------------
module "domain_spoke" {
  source   = "./modules/domain_spoke"
  for_each = local.domains

  domain_name            = each.key
  domain_owner           = each.value.owner
  prefix                 = local.prefix
  suffix                 = random_id.suffix.hex
  location               = var.location
  address_space          = each.value.address_space
  tenant_id              = var.tenant_id
  hub_vnet_id            = module.hub_network.hub_vnet_id
  hub_vnet_rg            = module.hub_network.hub_resource_group_name
  firewall_private_ip    = module.hub_network.firewall_private_ip
  pe_dns_zone_blob_id    = module.central_dns.zone_ids["blob"]
  pe_dns_zone_dfs_id     = module.central_dns.zone_ids["dfs"]
  pe_dns_zone_kv_id      = module.central_dns.zone_ids["keyvault"]
  log_analytics_id       = module.hub_network.log_analytics_id
  workspace_principal_id = module.databricks_workspace.managed_identity_principal_id
  tags = local.domain_tags[each.key]

  depends_on = [module.hub_network, module.central_dns]
}

# ---------------------------------------------------------------------------
# Unity Catalog – metastore + per-domain catalogs/schemas/grants
# ---------------------------------------------------------------------------
module "unity_catalog" {
  source = "./modules/unity_catalog"

  providers = {
    databricks.account   = databricks.account
    databricks.workspace = databricks.workspace
  }

  prefix               = local.prefix
  suffix               = random_id.suffix.hex
  location             = var.location
  workspace_id         = module.databricks_workspace.workspace_id
  workspace_number     = module.databricks_workspace.workspace_number
  metastore_storage_id = module.hub_network.metastore_storage_id
  tenant_id            = var.tenant_id
  admins_group_id      = var.databricks_admins_group_object_id

  domains = {
    for k, v in local.domains : k => {
      storage_account_id    = module.domain_spoke[k].storage_account_id
      storage_container_url = module.domain_spoke[k].adls_container_url
      connector_id          = module.domain_spoke[k].access_connector_id
      owners_group_id       = v.owners_group_id
      engineers_group_id    = v.engineers_group_id
      viewers_group_id      = v.viewers_group_id
      catalog_comment       = v.catalog_comment
      owner                 = v.owner
      teams_channel         = v.teams_channel
      subject_areas         = v.subject_areas
    }
  }

  depends_on = [module.databricks_workspace, module.domain_spoke]
}

# ---------------------------------------------------------------------------
# Key Vault–backed secret scopes (one per domain + one hub scope)
# ---------------------------------------------------------------------------
module "secret_scope" {
  source   = "./modules/secret_scope"
  for_each = local.domains

  providers = {
    databricks = databricks.workspace
  }

  scope_name   = each.key
  keyvault_id  = module.domain_spoke[each.key].keyvault_id
  keyvault_uri = module.domain_spoke[each.key].keyvault_uri

  depends_on = [module.databricks_workspace, module.domain_spoke]
}

module "hub_secret_scope" {
  source = "./modules/secret_scope"

  providers = {
    databricks = databricks.workspace
  }

  scope_name   = "hub"
  keyvault_id  = module.hub_keyvault.keyvault_id
  keyvault_uri = module.hub_keyvault.keyvault_uri

  depends_on = [module.databricks_workspace, module.hub_keyvault]
}
