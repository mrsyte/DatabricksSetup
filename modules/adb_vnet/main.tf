resource "azurerm_resource_group" "adb" {
  name     = "rg-${var.prefix}-adb-vnet"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Databricks VNet (spoke)
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "adb" {
  name                = "vnet-${var.prefix}-adb"
  location            = var.location
  resource_group_name = azurerm_resource_group.adb.name
  address_space       = [var.address_space]
  # Point DNS to firewall DNS proxy so private DNS zones are resolved
  dns_servers = [var.firewall_private_ip]
  tags        = var.tags
}

# Public subnet (host subnet) – Databricks worker VM NICs
resource "azurerm_subnet" "public" {
  name                 = "snet-adb-public"
  resource_group_name  = azurerm_resource_group.adb.name
  virtual_network_name = azurerm_virtual_network.adb.name
  address_prefixes     = [cidrsubnet(var.address_space, 9, 0)] # /25

  delegation {
    name = "databricks"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

# Private subnet (container subnet) – Databricks container VMs
resource "azurerm_subnet" "private" {
  name                 = "snet-adb-private"
  resource_group_name  = azurerm_resource_group.adb.name
  virtual_network_name = azurerm_virtual_network.adb.name
  address_prefixes     = [cidrsubnet(var.address_space, 9, 1)] # /25

  delegation {
    name = "databricks"
    service_delegation {
      name = "Microsoft.Databricks/workspaces"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/join/action",
        "Microsoft.Network/virtualNetworks/subnets/prepareNetworkPolicies/action",
        "Microsoft.Network/virtualNetworks/subnets/unprepareNetworkPolicies/action",
      ]
    }
  }
}

# Private endpoint subnet (no public IPs, no delegation)
resource "azurerm_subnet" "pe" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.adb.name
  virtual_network_name = azurerm_virtual_network.adb.name
  address_prefixes     = [cidrsubnet(var.address_space, 8, 2)] # /24
}

# ---------------------------------------------------------------------------
# NSGs – Databricks requires specific inbound/outbound rules
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "public" {
  name                = "nsg-${var.prefix}-adb-public"
  location            = var.location
  resource_group_name = azurerm_resource_group.adb.name
  tags                = var.tags
}

resource "azurerm_network_security_group" "private" {
  name                = "nsg-${var.prefix}-adb-private"
  location            = var.location
  resource_group_name = azurerm_resource_group.adb.name
  tags                = var.tags
}

# Required rules for ADB VNet injection
resource "azurerm_network_security_rule" "adb_public_inbound" {
  for_each                    = local.adb_nsg_rules_inbound
  name                        = each.key
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = each.value.port
  source_address_prefix       = each.value.source
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.adb.name
  network_security_group_name = azurerm_network_security_group.public.name
}

resource "azurerm_network_security_rule" "adb_public_outbound" {
  for_each                    = local.adb_nsg_rules_outbound
  name                        = each.key
  priority                    = each.value.priority
  direction                   = "Outbound"
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = each.value.port
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = each.value.destination
  resource_group_name         = azurerm_resource_group.adb.name
  network_security_group_name = azurerm_network_security_group.public.name
}

resource "azurerm_network_security_rule" "adb_private_inbound" {
  for_each                    = local.adb_nsg_rules_inbound
  name                        = each.key
  priority                    = each.value.priority
  direction                   = "Inbound"
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = each.value.port
  source_address_prefix       = each.value.source
  destination_address_prefix  = "VirtualNetwork"
  resource_group_name         = azurerm_resource_group.adb.name
  network_security_group_name = azurerm_network_security_group.private.name
}

resource "azurerm_network_security_rule" "adb_private_outbound" {
  for_each                    = local.adb_nsg_rules_outbound
  name                        = each.key
  priority                    = each.value.priority
  direction                   = "Outbound"
  access                      = each.value.access
  protocol                    = each.value.protocol
  source_port_range           = "*"
  destination_port_range      = each.value.port
  source_address_prefix       = "VirtualNetwork"
  destination_address_prefix  = each.value.destination
  resource_group_name         = azurerm_resource_group.adb.name
  network_security_group_name = azurerm_network_security_group.private.name
}

locals {
  adb_nsg_rules_inbound = {
    "AllowAzureDatabricksControlPlane" = {
      priority = 100
      access   = "Allow"
      protocol = "Tcp"
      port     = "22"
      source   = "AzureDatabricks"
    }
    "AllowVnetInbound" = {
      priority = 110
      access   = "Allow"
      protocol = "*"
      port     = "*"
      source   = "VirtualNetwork"
    }
    "DenyAllInbound" = {
      priority = 4096
      access   = "Deny"
      protocol = "*"
      port     = "*"
      source   = "*"
    }
  }

  adb_nsg_rules_outbound = {
    "AllowAzureDatabricksControlPlane" = {
      priority    = 100
      access      = "Allow"
      protocol    = "Tcp"
      port        = "443"
      destination = "AzureDatabricks"
    }
    "AllowSql" = {
      priority    = 110
      access      = "Allow"
      protocol    = "Tcp"
      port        = "3306"
      destination = "Sql"
    }
    "AllowStorage" = {
      priority    = 120
      access      = "Allow"
      protocol    = "Tcp"
      port        = "443"
      destination = "Storage"
    }
    "AllowVnetOutbound" = {
      priority    = 130
      access      = "Allow"
      protocol    = "*"
      port        = "*"
      destination = "VirtualNetwork"
    }
    "AllowInternetViaFirewall" = {
      priority    = 140
      access      = "Allow"
      protocol    = "Tcp"
      port        = "443"
      destination = "Internet"
    }
    "DenyAllOutbound" = {
      priority    = 4096
      access      = "Deny"
      protocol    = "*"
      port        = "*"
      destination = "*"
    }
  }
}

resource "azurerm_subnet_network_security_group_association" "public" {
  subnet_id                 = azurerm_subnet.public.id
  network_security_group_id = azurerm_network_security_group.public.id
}

resource "azurerm_subnet_network_security_group_association" "private" {
  subnet_id                 = azurerm_subnet.private.id
  network_security_group_id = azurerm_network_security_group.private.id
}

# ---------------------------------------------------------------------------
# Route table: force all egress via Azure Firewall
# ---------------------------------------------------------------------------
resource "azurerm_route_table" "adb" {
  name                          = "rt-${var.prefix}-adb"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.adb.name
  disable_bgp_route_propagation = true
  tags                          = var.tags

  route {
    name                   = "to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }

  # Databricks control plane must bypass firewall (service tag route)
  route {
    name           = "adb-control-plane"
    address_prefix = "AzureDatabricks"
    next_hop_type  = "Internet"
  }
}

resource "azurerm_subnet_route_table_association" "public" {
  subnet_id      = azurerm_subnet.public.id
  route_table_id = azurerm_route_table.adb.id
}

resource "azurerm_subnet_route_table_association" "private" {
  subnet_id      = azurerm_subnet.private.id
  route_table_id = azurerm_route_table.adb.id
}

# ---------------------------------------------------------------------------
# VNet peering: ADB spoke ↔ Hub
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "adb_to_hub" {
  name                      = "peer-adb-to-hub"
  resource_group_name       = azurerm_resource_group.adb.name
  virtual_network_name      = azurerm_virtual_network.adb.name
  remote_virtual_network_id = var.hub_vnet_id
  allow_forwarded_traffic   = true
  use_remote_gateways       = true
}

resource "azurerm_virtual_network_peering" "hub_to_adb" {
  name                      = "peer-hub-to-adb"
  resource_group_name       = var.hub_vnet_rg
  virtual_network_name      = regex(".+/virtualNetworks/([^/]+)$", var.hub_vnet_id)[0]
  remote_virtual_network_id = azurerm_virtual_network.adb.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = true
}
