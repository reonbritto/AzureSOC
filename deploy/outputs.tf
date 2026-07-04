output "resource_group_name" {
  description = "Resource group holding the honeynet VMs."
  value       = azurerm_resource_group.soc.name
}

output "windows_vm_public_ips" {
  description = "Public IPs of the Windows VMs."
  value       = azurerm_public_ip.win[*].ip_address
}

output "linux_vm_public_ip" {
  description = "Public IP of the Linux VM."
  value       = azurerm_public_ip.linux.ip_address
}

output "nsg_name" {
  description = "NSG name — add allow rules here to expose the honeynet (see docs/NEXT-STEPS.md)."
  value       = azurerm_network_security_group.soc.name
}
