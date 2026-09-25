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
# Central Private DNS – creates the 7 private zones, links hub VNet only.
# Each domain spoke registers itself with these zones (no dependency cycle).
# ---------------------------------------------------------------------------
module "central_dns" {
  source = "./modules/central_dns"

  prefix              = local.prefix
  location            = var.location
  resource_group_name = module.hub_network.dns_resource_group_name
  hub_vnet_id         = module.hub_network.hub_vnet_id
  tags                = merge(local.common_tags, { component = "dns" })

  depends_on = [module.hub_network]
}

# ---------------------------------------------------------------------------
# Per-domain spoke VNets + ADB workspace + storage + Key Vaults
# Each spoke also registers itself with the shared private DNS zones.
# ---------------------------------------------------------------------------
module "domain_spoke" {
  source   = "./modules/domain_spoke"
  for_each = local.domains

  domain_name             = each.key
  domain_owner            = each.value.owner
  prefix                  = local.prefix
  suffix                  = random_id.suffix.hex
  location                = var.location
  address_space           = each.value.address_space
  tenant_id               = var.tenant_id
  hub_vnet_id             = module.hub_network.hub_vnet_id
  hub_vnet_rg             = module.hub_network.hub_resource_group_name
  firewall_private_ip     = module.hub_network.firewall_private_ip
  dns_resource_group_name = module.hub_network.dns_resource_group_name
  pe_dns_zone_adb_id      = module.central_dns.zone_ids["adb"]
  pe_dns_zone_blob_id     = module.central_dns.zone_ids["blob"]
  pe_dns_zone_dfs_id      = module.central_dns.zone_ids["dfs"]
  pe_dns_zone_kv_id       = module.central_dns.zone_ids["keyvault"]
  log_analytics_id        = module.hub_network.log_analytics_id
  tags                    = local.domain_tags[each.key]

  depends_on = [module.hub_network, module.central_dns]
}

# ---------------------------------------------------------------------------
# Unity Catalog – metastore + per-domain catalogs/schemas/grants
# All operations use the account-level provider (no workspace provider needed)
# ---------------------------------------------------------------------------
module "unity_catalog" {
  source = "./modules/unity_catalog"

  providers = {
    databricks.account = databricks.account
  }

  prefix                        = local.prefix
  suffix                        = random_id.suffix.hex
  location                      = var.location
  metastore_storage_id          = module.hub_network.metastore_storage_id
  metastore_access_connector_id = module.hub_network.metastore_access_connector_id
  tenant_id                     = var.tenant_id
  admins_group_id               = var.databricks_admins_group_object_id

  domains = {
    for k, v in local.domains : k => {
      storage_account_id  = module.domain_spoke[k].storage_account_id
      adls_container_urls = module.domain_spoke[k].adls_container_urls
      connector_id        = module.domain_spoke[k].access_connector_id
      owners_group_id     = v.owners_group_id
      engineers_group_id  = v.engineers_group_id
      viewers_group_id    = v.viewers_group_id
      catalog_comment     = v.catalog_comment
      owner               = v.owner
      teams_channel       = v.teams_channel
      workspace_number    = module.domain_spoke[k].workspace_number
      subject_areas       = v.subject_areas
    }
  }

  depends_on = [module.domain_spoke]
}
