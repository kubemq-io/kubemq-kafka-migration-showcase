output "kafka_bootstrap_external" {
  description = "Kafka bootstrap servers reachable from the operator (port 9094)."
  value       = module.kafka.kafka_bootstrap_external
}

output "kafka_bootstrap_internal" {
  description = "Kafka bootstrap servers reachable inside the VPC (port 9092)."
  value       = module.kafka.kafka_bootstrap_internal
}

output "driver_ssh_command" {
  description = "Command that opens a shell on the Kafka driver VM."
  value       = module.kafka.driver_ssh_command
}

output "driver_public_ip" {
  description = "Public IP of the driver VM."
  value       = module.kafka.driver_public_ip
}

output "kubeconfig_command" {
  description = "Command that writes kubeconfig for the GKE cluster."
  value       = module.gke.kubeconfig_command
}

output "cluster_name" {
  description = "GKE cluster name."
  value       = module.gke.cluster_name
}

output "cluster_location" {
  description = "GKE cluster location (zone or region)."
  value       = module.gke.cluster_location
}

output "kubemq_namespace" {
  description = "Namespace KubeMQ will be installed into."
  value       = var.kubemq_namespace
}

output "storage_class" {
  description = "StorageClass for KubeMQ volumes."
  value       = module.gke.storage_class
}

output "kubernetes_pod_cidr" {
  description = "GKE pod CIDR (allowed through the Kafka firewall on 9092/9094)."
  value       = module.network.pods_cidr
}

output "hourly_cost_estimate" {
  description = "Static estimate for everything this root creates."
  value       = "about USD 2.50/h on-demand (estimate: Kafka ${module.kafka.hourly_cost_estimate}; GKE ${module.gke.hourly_cost_estimate}; plus NAT, static IPs and egress)"
}

output "project_id" {
  description = "Project id, echoed for the k8s-addons root."
  value       = var.project_id
}
