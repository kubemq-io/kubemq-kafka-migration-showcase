output "cluster_name" {
  description = "GKE cluster name."
  value       = google_container_cluster.this.name
}

output "cluster_location" {
  description = "Zone or region of the cluster."
  value       = google_container_cluster.this.location
}

output "endpoint" {
  description = "Kubernetes API endpoint."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64 cluster CA certificate."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Command that writes kubeconfig for this cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --location ${google_container_cluster.this.location} --project ${var.project_id}"
}

output "storage_class" {
  description = "StorageClass to use for KubeMQ volumes (GKE built-in, pd-balanced)."
  value       = "standard-rwo"
}

output "node_pool_id" {
  description = "Node pool id; use for ordering."
  value       = google_container_node_pool.primary.id
}

output "hourly_cost_estimate" {
  description = "Static on-demand estimate for 3x n2-standard-4 plus the GKE management fee."
  value       = "about USD 0.70/h on-demand (estimate: 3x n2-standard-4 at ~USD 0.19/h + GKE fee USD 0.10/h + disks)"
}
