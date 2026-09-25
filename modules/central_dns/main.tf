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
# Link each zone to the hub VNet only.
# Each domain spoke registers itself via its own VNet links
# (see modules/domain_spoke/main.tf) – this avoids a dependency cycle.
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_zone_virtual_network_link" "hub" {
  for_each = azurerm_private_dns_zone.zones

  name                  = "link-${each.key}-hub"
  resource_group_name   = var.resource_group_name
  private_dns_zone_name = each.value.name
  virtual_network_id    = var.hub_vnet_id
  registration_enabled  = false
  tags                  = var.tags
}
