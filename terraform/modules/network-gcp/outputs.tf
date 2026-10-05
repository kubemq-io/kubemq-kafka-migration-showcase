output "network_self_link" {
  description = "Self link of the VPC."
  value       = google_compute_network.this.self_link
}

output "network_name" {
  description = "Name of the VPC."
  value       = google_compute_network.this.name
}

output "subnet_self_link" {
  description = "Self link of the subnet."
  value       = google_compute_subnetwork.this.self_link
}

output "subnet_name" {
  description = "Name of the subnet."
  value       = google_compute_subnetwork.this.name
}

output "primary_cidr" {
  description = "Primary CIDR of the subnet."
  value       = google_compute_subnetwork.this.ip_cidr_range
}

output "pods_cidr" {
  description = "Secondary range \"pods\" CIDR."
  value       = var.pods_cidr
}

output "services_cidr" {
  description = "Secondary range \"services\" CIDR."
  value       = var.services_cidr
}

output "pods_range_name" {
  description = "Name of the pods secondary range."
  value       = "pods"
}

output "services_range_name" {
  description = "Name of the services secondary range."
  value       = "services"
}
