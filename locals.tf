locals {
  prefix = "adb-${var.environment}"

  # Platform-level tags applied to every Azure resource
  common_tags = merge(
    {
      app         = var.app_name
      environment = var.environment
      owner       = var.owner
      cost_center = var.cost_center
      location    = var.location
      managed_by  = "terraform"
    },
    var.tags
  )

  # Databricks workspace-level custom tags applied to every cluster via policy.
  # These flow to Azure VMs for cost allocation.
  databricks_default_cluster_tags = {
    app         = var.app_name
    environment = var.environment
    owner       = var.owner
    cost_center = var.cost_center
    managed_by  = "databricks"
  }

  # Private DNS zones required for Azure Databricks + dependencies.
  # Defined here for reference; central_dns module receives them via spoke_vnet_ids.
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
