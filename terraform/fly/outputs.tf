output "app_url" {
  description = "URL of the deployed application"
  value       = "https://${var.app_name}.fly.dev"
}

output "ipv4_address" {
  description = "IPv4 address"
  value       = fly_ip.ipv4.address
}

output "ipv6_address" {
  description = "IPv6 address"
  value       = fly_ip.ipv6.address
}
