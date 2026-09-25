data "azurerm_client_config" "current" {}

locals {
  safe_domain = replace(var.domain_name, "_", "-")

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

resource "azurerm_resource_group" "spoke" {
  name     = "rg-${var.prefix}-domain-${local.safe_domain}"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Spoke VNet – shared by domain data services and ADB VNet injection
#
# Subnet layout within var.address_space:
#   /24  index 0  → private endpoints
#   /24  index 1  → data services (storage, KV access)
#   /25  index 4  → ADB public (host) subnet
#   /25  index 5  → ADB private (container) subnet
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "spoke" {
  name                = "vnet-${var.prefix}-${local.safe_domain}"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  address_space       = [var.address_space]
  dns_servers         = [var.firewall_private_ip]
  tags                = var.tags
}

resource "azurerm_subnet" "pe" {
  name                 = "snet-private-endpoints"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.address_space, 8, 0)]
}

resource "azurerm_subnet" "data" {
  name                 = "snet-data-services"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.address_space, 8, 1)]
}

# ADB host subnet (public) – Databricks worker VM NICs
resource "azurerm_subnet" "adb_public" {
  name                 = "snet-adb-public"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.address_space, 9, 4)]

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

# ADB container subnet (private)
resource "azurerm_subnet" "adb_private" {
  name                 = "snet-adb-private"
  resource_group_name  = azurerm_resource_group.spoke.name
  virtual_network_name = azurerm_virtual_network.spoke.name
  address_prefixes     = [cidrsubnet(var.address_space, 9, 5)]

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

# ---------------------------------------------------------------------------
# NSGs for ADB subnets
# ---------------------------------------------------------------------------
resource "azurerm_network_security_group" "adb_public" {
  name                = "nsg-${var.prefix}-${local.safe_domain}-adb-public"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags
}

resource "azurerm_network_security_group" "adb_private" {
  name                = "nsg-${var.prefix}-${local.safe_domain}-adb-private"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags
}

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
  resource_group_name         = azurerm_resource_group.spoke.name
  network_security_group_name = azurerm_network_security_group.adb_public.name
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
  resource_group_name         = azurerm_resource_group.spoke.name
  network_security_group_name = azurerm_network_security_group.adb_public.name
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
  resource_group_name         = azurerm_resource_group.spoke.name
  network_security_group_name = azurerm_network_security_group.adb_private.name
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
  resource_group_name         = azurerm_resource_group.spoke.name
  network_security_group_name = azurerm_network_security_group.adb_private.name
}

resource "azurerm_subnet_network_security_group_association" "adb_public" {
  subnet_id                 = azurerm_subnet.adb_public.id
  network_security_group_id = azurerm_network_security_group.adb_public.id
}

resource "azurerm_subnet_network_security_group_association" "adb_private" {
  subnet_id                 = azurerm_subnet.adb_private.id
  network_security_group_id = azurerm_network_security_group.adb_private.id
}

# ---------------------------------------------------------------------------
# Route table: force ADB egress via firewall, bypass control plane
# ---------------------------------------------------------------------------
resource "azurerm_route_table" "adb" {
  name                          = "rt-${var.prefix}-${local.safe_domain}-adb"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.spoke.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags

  route {
    name                   = "to-firewall"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = var.firewall_private_ip
  }

  route {
    name           = "adb-control-plane"
    address_prefix = "AzureDatabricks"
    next_hop_type  = "Internet"
  }
}

resource "azurerm_subnet_route_table_association" "adb_public" {
  subnet_id      = azurerm_subnet.adb_public.id
  route_table_id = azurerm_route_table.adb.id
}

resource "azurerm_subnet_route_table_association" "adb_private" {
  subnet_id      = azurerm_subnet.adb_private.id
  route_table_id = azurerm_route_table.adb.id
}

# ---------------------------------------------------------------------------
# Private DNS zone VNet links – register this spoke with all shared zones.
# Zone names are the standard Azure Private Link FQDNs (constant values).
# ---------------------------------------------------------------------------
locals {
  private_dns_zones = {
    "adb"        = "privatelink.azuredatabricks.net"
    "blob"       = "privatelink.blob.core.windows.net"
    "dfs"        = "privatelink.dfs.core.windows.net"
    "queue"      = "privatelink.queue.core.windows.net"
    "keyvault"   = "privatelink.vaultcore.azure.net"
    "servicebus" = "privatelink.servicebus.windows.net"
    "eventhub"   = "privatelink.eventhub.windows.net"
  }
}

resource "azurerm_private_dns_zone_virtual_network_link" "spoke" {
  for_each = local.private_dns_zones

  name                  = "link-${each.key}-${local.safe_domain}"
  resource_group_name   = var.dns_resource_group_name
  private_dns_zone_name = each.value
  virtual_network_id    = azurerm_virtual_network.spoke.id
  registration_enabled  = false
  tags                  = var.tags
}

# ---------------------------------------------------------------------------
# VNet peering: spoke ↔ hub
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  name                      = "peer-${local.safe_domain}-to-hub"
  resource_group_name       = azurerm_resource_group.spoke.name
  virtual_network_name      = azurerm_virtual_network.spoke.name
  remote_virtual_network_id = var.hub_vnet_id
  allow_forwarded_traffic   = true
  use_remote_gateways       = true
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  name                      = "peer-hub-to-${local.safe_domain}"
  resource_group_name       = var.hub_vnet_rg
  virtual_network_name      = regex(".+/virtualNetworks/([^/]+)$", var.hub_vnet_id)[0]
  remote_virtual_network_id = azurerm_virtual_network.spoke.id
  allow_forwarded_traffic   = true
  allow_gateway_transit     = true
}

# ---------------------------------------------------------------------------
# ADLS Gen2 Storage Account – one storage account, three env containers
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "domain" {
  name                            = "st${replace(var.prefix, "-", "")}${substr(replace(local.safe_domain, "-", ""), 0, 8)}${var.suffix}"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.spoke.name
  account_tier                    = "Standard"
  account_replication_type        = "GRS"
  account_kind                    = "StorageV2"
  is_hns_enabled                  = true
  allow_nested_items_to_be_public = false
  min_tls_version                 = "TLS1_2"
  public_network_access_enabled   = false

  blob_properties {
    versioning_enabled       = true
    change_feed_enabled      = true
    last_access_time_enabled = true

    delete_retention_policy {
      days = 30
    }

    container_delete_retention_policy {
      days = 7
    }
  }

  tags = var.tags
}

# One container per environment – each becomes a Unity Catalog external location
resource "azurerm_storage_container" "env" {
  for_each              = toset(["dev", "test", "prod"])
  name                  = each.key
  storage_account_name  = azurerm_storage_account.domain.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "checkpoints" {
  name                  = "checkpoints"
  storage_account_name  = azurerm_storage_account.domain.name
  container_access_type = "private"
}

# Private endpoints for blob + dfs (ADLS Gen2 requires both)
resource "azurerm_private_endpoint" "blob" {
  name                = "pe-${local.safe_domain}-blob"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-blob"
    private_connection_resource_id = azurerm_storage_account.domain.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob-dns"
    private_dns_zone_ids = [var.pe_dns_zone_blob_id]
  }
}

resource "azurerm_private_endpoint" "dfs" {
  name                = "pe-${local.safe_domain}-dfs"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-dfs"
    private_connection_resource_id = azurerm_storage_account.domain.id
    subresource_names              = ["dfs"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "dfs-dns"
    private_dns_zone_ids = [var.pe_dns_zone_dfs_id]
  }
}

# ---------------------------------------------------------------------------
# Azure Access Connector (MSI-based UC storage access)
# ---------------------------------------------------------------------------
resource "azurerm_databricks_access_connector" "domain" {
  name                = "aac-${var.prefix}-${local.safe_domain}"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  tags                = var.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_role_assignment" "connector_storage" {
  scope                = azurerm_storage_account.domain.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_access_connector.domain.identity[0].principal_id
}

# ---------------------------------------------------------------------------
# Domain Key Vault
# ---------------------------------------------------------------------------
resource "azurerm_key_vault" "domain" {
  name                          = "kv-${var.prefix}-${substr(local.safe_domain, 0, 8)}-${var.suffix}"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.spoke.name
  tenant_id                     = var.tenant_id
  sku_name                      = "standard"
  enable_rbac_authorization     = true
  soft_delete_retention_days    = 90
  purge_protection_enabled      = true
  public_network_access_enabled = false

  network_acls {
    bypass         = "AzureServices"
    default_action = "Deny"
    ip_rules       = []
  }

  tags = var.tags
}

resource "azurerm_role_assignment" "deployer_kv_admin" {
  scope                = azurerm_key_vault.domain.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_private_endpoint" "kv" {
  name                = "pe-${local.safe_domain}-kv"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-kv"
    private_connection_resource_id = azurerm_key_vault.domain.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "kv-dns"
    private_dns_zone_ids = [var.pe_dns_zone_kv_id]
  }
}

# ---------------------------------------------------------------------------
# Databricks Workspace (per-domain, VNet-injected into spoke)
# ---------------------------------------------------------------------------
resource "azurerm_databricks_workspace" "domain" {
  name                        = "adb-${var.prefix}-${local.safe_domain}-${var.suffix}"
  location                    = var.location
  resource_group_name         = azurerm_resource_group.spoke.name
  sku                         = "premium"
  managed_resource_group_name = "rg-${var.prefix}-${local.safe_domain}-adb-managed"

  public_network_access_enabled         = false
  network_security_group_rules_required = "NoAzureDatabricksRules"

  custom_parameters {
    no_public_ip                                         = true
    public_subnet_name                                   = azurerm_subnet.adb_public.name
    private_subnet_name                                  = azurerm_subnet.adb_private.name
    virtual_network_id                                   = azurerm_virtual_network.spoke.id
    public_subnet_network_security_group_association_id  = azurerm_subnet_network_security_group_association.adb_public.id
    private_subnet_network_security_group_association_id = azurerm_subnet_network_security_group_association.adb_private.id
  }

  tags = var.tags

  depends_on = [
    azurerm_subnet_route_table_association.adb_public,
    azurerm_subnet_route_table_association.adb_private,
  ]
}

# Private endpoints for workspace UI and browser auth
resource "azurerm_private_endpoint" "adb_workspace" {
  name                = "pe-${local.safe_domain}-adb-ws"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-adb-workspace"
    private_connection_resource_id = azurerm_databricks_workspace.domain.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "adb-dns"
    private_dns_zone_ids = [var.pe_dns_zone_adb_id]
  }
}

resource "azurerm_private_endpoint" "adb_auth" {
  name                = "pe-${local.safe_domain}-adb-auth"
  location            = var.location
  resource_group_name = azurerm_resource_group.spoke.name
  subnet_id           = azurerm_subnet.pe.id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-adb-auth"
    private_connection_resource_id = azurerm_databricks_workspace.domain.id
    subresource_names              = ["browser_authentication"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "adb-auth-dns"
    private_dns_zone_ids = [var.pe_dns_zone_adb_id]
  }
}

# Grant workspace MSI access to domain storage and Key Vault
resource "azurerm_role_assignment" "workspace_storage" {
  scope                = azurerm_storage_account.domain.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_databricks_workspace.domain.storage_account_identity[0].principal_id
  depends_on           = [azurerm_databricks_workspace.domain]
}

resource "azurerm_role_assignment" "workspace_kv_reader" {
  scope                = azurerm_key_vault.domain.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_databricks_workspace.domain.storage_account_identity[0].principal_id
  depends_on           = [azurerm_databricks_workspace.domain]
}

# ---------------------------------------------------------------------------
# Diagnostics
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "workspace" {
  name                       = "diag-adb-workspace"
  target_resource_id         = azurerm_databricks_workspace.domain.id
  log_analytics_workspace_id = var.log_analytics_id

  enabled_log { category = "dbfs" }
  enabled_log { category = "clusters" }
  enabled_log { category = "accounts" }
  enabled_log { category = "jobs" }
  enabled_log { category = "notebook" }
  enabled_log { category = "ssh" }
  enabled_log { category = "workspace" }
  enabled_log { category = "secrets" }
  enabled_log { category = "sqlPermissions" }
  enabled_log { category = "instancePools" }
  enabled_log { category = "sqlanalytics" }
  enabled_log { category = "genie" }
  enabled_log { category = "globalInitScripts" }
  enabled_log { category = "iamRole" }
  enabled_log { category = "mlflowExperiment" }
  enabled_log { category = "featureStore" }
  enabled_log { category = "RemoteHistoryService" }
  enabled_log { category = "databrickssql" }
  enabled_log { category = "deltaPipelines" }
  enabled_log { category = "modelRegistry" }
  enabled_log { category = "repos" }
  enabled_log { category = "unityCatalog" }
  enabled_log { category = "gitCredentials" }
  enabled_log { category = "webTerminal" }
  enabled_log { category = "serverlessRealTimeInference" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "storage" {
  name                       = "diag-storage"
  target_resource_id         = "${azurerm_storage_account.domain.id}/blobServices/default"
  log_analytics_workspace_id = var.log_analytics_id

  enabled_log { category = "StorageRead" }
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }

  metric {
    category = "Transaction"
    enabled  = true
  }
}

resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "diag-kv"
  target_resource_id         = azurerm_key_vault.domain.id
  log_analytics_workspace_id = var.log_analytics_id

  enabled_log { category = "AuditEvent" }

  metric {
    category = "AllMetrics"
    enabled  = true
  }
}
