locals {
  zones = {
    "adb"        = "privatelink.azuredatabricks.net"
    "blob"       = "privatelink.blob.core.windows.net"
    "dfs"        = "privatelink.dfs.core.windows.net"
    "queue"      = "privatelink.queue.core.windows.net"
    "keyvault"   = "privatelink.vaultcore.azure.net"
    "servicebus" = "privatelink.servicebus.windows.net"
    "eventhub"   = "privatelink.eventhub.windows.net"
  }

  # All VNets that need links: hub + every spoke
  all_vnet_ids = merge(
    { hub = var.hub_vnet_id },
    var.spoke_vnet_ids
  )
}

# ---------------------------------------------------------------------------
# Private DNS Zones
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone" "zones" {
  for_each            = local.zones
  name                = each.value
  resource_group_name = var.resource_group_name
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Link each zone to the hub VNet + all spoke VNets
# Flat key: "{zone_key}-{vnet_key}"
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone_virtual_network_link" "links" {
  for_each = {
    for pair in flatten([
      for zone_key, zone in azurerm_private_dns_zone.zones : [
        for vnet_key, vnet_id in local.all_vnet_ids : {
          key       = "${zone_key}-${vnet_key}"
          zone_name = zone.name
          vnet_id   = vnet_id
        }
      ]
    ]) : pair.key => pair
  }

  name                  = "link-${each.key}"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.zone_name
  virtual_network_id    = each.value.vnet_id
  registration_enabled  = false
  tags                  = var.tags
}
