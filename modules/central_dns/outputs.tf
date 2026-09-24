output "zone_ids" {
  description = "Map of zone short-key → private DNS zone ID"
  value       = { for k, v in azurerm_private_dns_zone.zones : k => v.id }
}

output "zone_names" {
  description = "Map of zone short-key → DNS zone FQDN"
  value       = { for k, v in azurerm_private_dns_zone.zones : k => v.name }
}
