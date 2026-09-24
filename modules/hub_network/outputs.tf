output "hub_resource_group_name" {
  value = azurerm_resource_group.hub.name
}

output "dns_resource_group_name" {
  value = azurerm_resource_group.dns.name
}

output "hub_vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "hub_vnet_name" {
  value = azurerm_virtual_network.hub.name
}

output "firewall_private_ip" {
  value = azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

output "vpn_gateway_public_ip" {
  value = azurerm_public_ip.vpn_gw.ip_address
}

output "log_analytics_id" {
  value = azurerm_log_analytics_workspace.hub.id
}

output "dns_resolver_inbound_ip" {
  value = azurerm_private_dns_resolver_inbound_endpoint.hub.ip_configurations[0].private_ip_address
}

output "metastore_storage_id" {
  value = "${azurerm_storage_account.metastore.id}/blobServices/default/containers/${azurerm_storage_container.metastore.name}"
}
