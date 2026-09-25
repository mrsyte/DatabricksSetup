# ---------------------------------------------------------------------------
# Resource groups
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "hub" {
  name     = "rg-${var.prefix}-hub"
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "dns" {
  name     = "rg-${var.prefix}-dns"
  location = var.location
  tags     = var.tags
}

resource "azurerm_resource_group" "metastore_storage" {
  name     = "rg-${var.prefix}-uc-storage"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Log Analytics Workspace (centralised)
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "hub" {
  name                = "law-${var.prefix}-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "PerGB2018"
  retention_in_days   = 90
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Hub VNet
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.prefix}-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  address_space       = [var.address_space]
  # Use Azure DNS – private resolver handles custom resolution
  dns_servers = []
  tags        = var.tags
}

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space, 11, 0)] # /27
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space, 10, 4)] # /26
}

resource "azurerm_subnet" "firewall_mgmt" {
  name                 = "AzureFirewallManagementSubnet"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space, 10, 5)] # /26
}

resource "azurerm_subnet" "dns_inbound" {
  name                 = "snet-dns-inbound"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space, 12, 48)] # /28

  delegation {
    name = "dns-resolver"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "dns_outbound" {
  name                 = "snet-dns-outbound"
  resource_group_name  = azurerm_resource_group.hub.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [cidrsubnet(var.address_space, 12, 49)] # /28

  delegation {
    name = "dns-resolver"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ---------------------------------------------------------------------------
# Azure Firewall (Standard tier + DNS proxy enabled)
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "firewall" {
  name                = "pip-${var.prefix}-fw"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_public_ip" "firewall_mgmt" {
  name                = "pip-${var.prefix}-fw-mgmt"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_firewall_policy" "hub" {
  name                = "afwp-${var.prefix}-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  sku                 = "Standard"

  dns {
    proxy_enabled = true # Forces spoke traffic to use firewall as DNS forwarder
    servers       = []   # Azure-provided DNS upstream
  }

  insights {
    enabled                            = true
    default_log_analytics_workspace_id = azurerm_log_analytics_workspace.hub.id
    retention_in_days                  = 30
  }

  tags = var.tags
}

# Application rule collection: Databricks control plane egress
resource "azurerm_firewall_policy_rule_collection_group" "databricks" {
  name               = "rcg-databricks"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  priority           = 200

  application_rule_collection {
    name     = "arc-databricks-control-plane"
    action   = "Allow"
    priority = 210

    rule {
      name             = "adb-control-plane"
      source_addresses = ["*"]
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdns = [
        "*.azuredatabricks.net",
        "adb-*.azuredatabricks.net",
        "cdn.azuredatabricks.com",
      ]
    }

    rule {
      name             = "adb-dependencies"
      source_addresses = ["*"]
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdns = [
        "login.microsoftonline.com",
        "management.azure.com",
        "*.blob.core.windows.net",
        "*.dfs.core.windows.net",
        "*.queue.core.windows.net",
        "*.vault.azure.net",
        "*.servicebus.windows.net",
        "*.eventhub.windows.net",
        "packages.microsoft.com",
        "pypi.org",
        "files.pythonhosted.org",
        "*.pypi.org",
        "repo1.maven.org",
        "search.maven.org",
        "mirror.centos.org",
      ]
    }

    rule {
      name             = "ubuntu-updates"
      source_addresses = ["*"]
      protocols {
        type = "Http"
        port = 80
      }
      protocols {
        type = "Https"
        port = 443
      }
      destination_fqdns = [
        "security.ubuntu.com",
        "azure.archive.ubuntu.com",
        "changelogs.ubuntu.com",
      ]
    }
  }

  network_rule_collection {
    name     = "nrc-databricks-tcp"
    action   = "Allow"
    priority = 220

    rule {
      name                  = "adb-webapp-port"
      source_addresses      = ["*"]
      destination_addresses = ["AzureDatabricks"]
      protocols             = ["TCP"]
      destination_ports     = ["443"]
    }

    rule {
      name                  = "adb-sql-metastore"
      source_addresses      = ["*"]
      destination_addresses = ["Sql"]
      protocols             = ["TCP"]
      destination_ports     = ["3306", "1433"]
    }

    rule {
      name                  = "adb-storage"
      source_addresses      = ["*"]
      destination_addresses = ["Storage"]
      protocols             = ["TCP"]
      destination_ports     = ["443"]
    }

    rule {
      name                  = "adb-event-hub"
      source_addresses      = ["*"]
      destination_addresses = ["EventHub"]
      protocols             = ["TCP"]
      destination_ports     = ["9093"]
    }
  }
}

resource "azurerm_firewall" "hub" {
  name                = "afw-${var.prefix}-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.hub.id
  zones               = ["1", "2", "3"]

  ip_configuration {
    name                 = "pip-config"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.firewall.id
  }

  management_ip_configuration {
    name                 = "mgmt-config"
    subnet_id            = azurerm_subnet.firewall_mgmt.id
    public_ip_address_id = azurerm_public_ip.firewall_mgmt.id
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# VPN Gateway (P2S – AAD/Entra auth so users on VPN can reach private link)
# ---------------------------------------------------------------------------
resource "azurerm_public_ip" "vpn_gw" {
  name                = "pip-${var.prefix}-vpngw"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  allocation_method   = "Static"
  sku                 = "Standard"
  zones               = ["1", "2", "3"]
  tags                = var.tags
}

resource "azurerm_virtual_network_gateway" "vpn" {
  name                = "vpng-${var.prefix}-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.hub.name
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = "VpnGw2AZ"
  active_active       = false
  enable_bgp          = false

  ip_configuration {
    name                          = "vnetGatewayConfig"
    public_ip_address_id          = azurerm_public_ip.vpn_gw.id
    subnet_id                     = azurerm_subnet.gateway.id
    private_ip_address_allocation = "Dynamic"
  }

  vpn_client_configuration {
    address_space        = var.vpn_client_pool
    vpn_client_protocols = ["OpenVPN"]
    vpn_auth_types       = ["AAD"]

    aad_tenant   = "https://login.microsoftonline.com/${var.tenant_id}"
    aad_audience = var.vpn_aad_audience
    aad_issuer   = "https://sts.windows.net/${var.tenant_id}/"
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# DNS Private Resolver (hub – authoritative for private link zones)
# ---------------------------------------------------------------------------
resource "azurerm_private_dns_resolver" "hub" {
  name                = "dnspr-${var.prefix}-hub"
  location            = var.location
  resource_group_name = azurerm_resource_group.dns.name
  virtual_network_id  = azurerm_virtual_network.hub.id
  tags                = var.tags
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "hub" {
  name                    = "ep-inbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  location                = var.location

  ip_configurations {
    private_ip_allocation_method = "Dynamic"
    subnet_id                    = azurerm_subnet.dns_inbound.id
  }
}

resource "azurerm_private_dns_resolver_outbound_endpoint" "hub" {
  name                    = "ep-outbound"
  private_dns_resolver_id = azurerm_private_dns_resolver.hub.id
  location                = var.location
  subnet_id               = azurerm_subnet.dns_outbound.id
}

# ---------------------------------------------------------------------------
# Unity Catalog root storage (shared metastore)
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "metastore" {
  name                            = "stucmeta${replace(var.prefix, "-", "")}"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.metastore_storage.name
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"

  blob_properties {
    versioning_enabled = true
  }

  tags = var.tags
}

resource "azurerm_storage_container" "metastore" {
  name                  = "metastore"
  storage_account_name  = azurerm_storage_account.metastore.name
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Access Connector for Unity Catalog metastore root storage
# ---------------------------------------------------------------------------
resource "azurerm_databricks_access_connector" "metastore" {
  name                = "aac-${var.prefix}-metastore"
  location            = var.location
  resource_group_name = azurerm_resource_group.metastore_storage.name
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "metastore_connector_storage" {
  scope                = azurerm_storage_account.metastore.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.metastore.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Diagnostic settings for Firewall → Log Analytics
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "firewall" {
  count                      = var.log_analytics_id != null ? 1 : 0
  name                       = "diag-fw"
  target_resource_id         = azurerm_firewall.hub.id
  log_analytics_workspace_id = var.log_analytics_id

  enabled_log { category = "AZFWApplicationRule" }
  enabled_log { category = "AZFWNetworkRule" }
  enabled_log { category = "AZFWThreatIntel" }
  enabled_log { category = "AZFWDnsQuery" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
