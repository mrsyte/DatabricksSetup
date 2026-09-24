output "vnet_id" {
  value = azurerm_virtual_network.adb.id
}

output "resource_group_name" {
  value = azurerm_resource_group.adb.name
}

output "public_subnet_name" {
  value = azurerm_subnet.public.name
}

output "private_subnet_name" {
  value = azurerm_subnet.private.name
}

output "public_subnet_nsg_id" {
  value = azurerm_network_security_group.public.id
}

output "private_subnet_nsg_id" {
  value = azurerm_network_security_group.private.id
}

output "pe_subnet_id" {
  value = azurerm_subnet.pe.id
}
