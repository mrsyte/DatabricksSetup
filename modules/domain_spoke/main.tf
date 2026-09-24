data "azurerm_client_config" "current" {}

locals {
  safe_domain = replace(var.domain_name, "_", "-")
}

resource "azurerm_resource_group" "spoke" {
  name     = "rg-${var.prefix}-domain-${local.safe_domain}"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Spoke VNet
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
# ADLS Gen2 Storage Account (Unity Catalog external location)
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

resource "azurerm_storage_container" "data" {
  name                  = "data"
  storage_account_name  = azurerm_storage_account.domain.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "checkpoints" {
  name                  = "checkpoints"
  storage_account_name  = azurerm_storage_account.domain.name
  container_access_type = "private"
}

# Grant workspace MSI write access to domain storage
resource "azurerm_role_assignment" "workspace_storage" {
  scope                = azurerm_storage_account.domain.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.workspace_principal_id
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
# Azure Access Connector (lets Unity Catalog access ADLS without credentials)
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

resource "azurerm_role_assignment" "workspace_kv_reader" {
  scope                = azurerm_key_vault.domain.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = var.workspace_principal_id
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
# Diagnostics
# ---------------------------------------------------------------------------
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
