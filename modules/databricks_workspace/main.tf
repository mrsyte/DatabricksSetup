terraform {
  required_providers {
    databricks = {
      source = "databricks/databricks"
    }
  }
}

resource "azurerm_resource_group" "adb_ws" {
  name     = "rg-${var.prefix}-adb-workspace"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Managed Resource Group (ADB managed resources land here)
# ---------------------------------------------------------------------------
locals {
  managed_rg_name = "rg-${var.prefix}-adb-managed"
}

# ---------------------------------------------------------------------------
# Azure Databricks Workspace
# Secure defaults: NPIP, private link, VNet injection
# ---------------------------------------------------------------------------
resource "azurerm_databricks_workspace" "main" {
  name                        = "adb-${var.prefix}-${var.suffix}"
  location                    = var.location
  resource_group_name         = azurerm_resource_group.adb_ws.name
  sku                         = "premium"
  managed_resource_group_name = local.managed_rg_name

  # Disable all public network paths
  public_network_access_enabled         = false
  network_security_group_rules_required = "NoAzureDatabricksRules"

  custom_parameters {
    no_public_ip                                         = true
    public_subnet_name                                   = var.public_subnet_name
    private_subnet_name                                  = var.private_subnet_name
    virtual_network_id                                   = var.adb_vnet_id
    public_subnet_network_security_group_association_id  = var.public_subnet_nsg_id
    private_subnet_network_security_group_association_id = var.private_subnet_nsg_id
  }

  tags = var.tags

  # Workspace must be fully created before private endpoints are attached
  lifecycle {
    ignore_changes = [
      # Managed resource group is auto-created; prevent drift
      managed_resource_group_name
    ]
  }
}

# ---------------------------------------------------------------------------
# Private Endpoints (workspace + auth + browser_auth)
# ---------------------------------------------------------------------------
resource "azurerm_private_endpoint" "workspace" {
  name                = "pe-${var.prefix}-adb-ws"
  location            = var.location
  resource_group_name = azurerm_resource_group.adb_ws.name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-adb-workspace"
    private_connection_resource_id = azurerm_databricks_workspace.main.id
    subresource_names              = ["databricks_ui_api"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "adb-dns"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

resource "azurerm_private_endpoint" "auth" {
  name                = "pe-${var.prefix}-adb-auth"
  location            = var.location
  resource_group_name = azurerm_resource_group.adb_ws.name
  subnet_id           = var.pe_subnet_id
  tags                = var.tags

  private_service_connection {
    name                           = "psc-adb-auth"
    private_connection_resource_id = azurerm_databricks_workspace.main.id
    subresource_names              = ["browser_authentication"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "adb-auth-dns"
    private_dns_zone_ids = [var.private_dns_zone_id]
  }
}

# ---------------------------------------------------------------------------
# Diagnostic settings → Log Analytics
# ---------------------------------------------------------------------------
resource "azurerm_monitor_diagnostic_setting" "workspace" {
  name                       = "diag-adb-workspace"
  target_resource_id         = azurerm_databricks_workspace.main.id
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

# ---------------------------------------------------------------------------
# Default cluster policy – enforces mandatory tags on every cluster
# Tags flow to Azure VMs so cost allocation works per app/domain/owner
# ---------------------------------------------------------------------------
resource "databricks_cluster_policy" "default_tags" {
  name = "Platform Default – Required Tags"

  definition = jsonencode({
    "custom_tags.app" = {
      type  = "fixed"
      value = lookup(var.default_cluster_tags, "app", "databricks-platform")
    }
    "custom_tags.environment" = {
      type  = "fixed"
      value = lookup(var.default_cluster_tags, "environment", "prod")
    }
    "custom_tags.cost_center" = {
      type  = "fixed"
      value = lookup(var.default_cluster_tags, "cost_center", "data-platform")
    }
    "custom_tags.managed_by" = {
      type  = "fixed"
      value = "databricks"
    }
    # owner and domain are user-supplied per cluster (required but not fixed)
    "custom_tags.owner" = {
      type     = "regex"
      pattern  = ".+"
      defaultValue = lookup(var.default_cluster_tags, "owner", "")
    }
    "custom_tags.domain" = {
      type     = "regex"
      pattern  = ".+"
      defaultValue = ""
    }
  })
}

# ---------------------------------------------------------------------------
# Workspace configuration – enforce security settings
# ---------------------------------------------------------------------------
resource "databricks_workspace_conf" "security" {
  custom_config = {
    # Prevent notebooks from connecting to external storage without cluster policy
    "enableResultsDownloading"            = "false"
    "enableExportNotebook"                = "false"
    # Require cluster policies on all clusters
    "enableClusterAccessControl"          = "true"
    "enableWorkspaceFilesystem"           = "false"
    "enableTokensConfig"                  = "true"
    "maxTokenLifetimeDays"                = "90"
    "enableJobsAccessControl"             = "true"
    "enableNotebookTableClipboard"        = "false"
  }
}
