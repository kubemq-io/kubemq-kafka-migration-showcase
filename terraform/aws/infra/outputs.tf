output "kafka_bootstrap_external" {
  description = "Kafka EXTERNAL bootstrap (public IP:9094 x3), reachable from operator_cidr only."
  value       = module.kafka.kafka_bootstrap_external
}

output "kafka_bootstrap_internal" {
  description = "Kafka INTERNAL bootstrap (private IP:9092 x3), reachable from inside the VPC (driver, Kubernetes pods)."
  value       = module.kafka.kafka_bootstrap_internal
}

output "driver_ssh_command" {
  description = "SSH command for the Kafka driver VM."
  value       = module.kafka.driver_ssh_command
}

output "driver_public_ip" {
  description = "Elastic IP of the Kafka driver VM."
  value       = module.kafka.driver_public_ip
}

output "kubeconfig_command" {
  description = "Writes kubeconfig for the EKS cluster."
  value       = module.eks.kubeconfig_command
}

output "cluster_name" {
  description = "EKS cluster name (input for the k8s-addons root)."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region (input for the k8s-addons root)."
  value       = var.region
}

output "kubemq_namespace" {
  description = "Namespace KubeMQ will be installed into."
  value       = var.kubemq_namespace
}

output "storage_class" {
  description = "Default StorageClass name created by the k8s-addons root."
  value       = module.eks.storage_class
}

output "kubernetes_pod_cidr" {
  description = "On EKS with the VPC CNI, pods take addresses from the VPC itself; this is the VPC CIDR. Present for parity with the GCP root."
  value       = module.network.vpc_cidr
}

output "hourly_cost_estimate" {
  description = "Static on-demand list-price estimate for everything this root creates (Kafka VMs + EIPs, EKS control plane + nodes, NAT gateway). Excludes data transfer and EBS."
  value       = format("USD %.2f/h on-demand (estimate: Kafka %.2f + EKS %.2f + NAT gateway %.3f)", module.kafka.hourly_cost_usd + module.eks.hourly_cost_usd + local.hourly_nat_usd, module.kafka.hourly_cost_usd, module.eks.hourly_cost_usd, local.hourly_nat_usd)
}

output "kafka_hourly_cost_estimate" {
  description = "Kafka VMs and EIPs only."
  value       = module.kafka.hourly_cost_estimate
}

output "eks_hourly_cost_estimate" {
  description = "EKS control plane and worker nodes only."
  value       = module.eks.hourly_cost_estimate
}

output "vpc_id" {
  description = "Dedicated VPC id (useful for scripts/verify-teardown.sh)."
  value       = module.network.vpc_id
}

output "brokers_security_group_id" {
  description = "Security group of the Kafka brokers."
  value       = module.kafka.brokers_security_group_id
}

output "eks_node_security_group_id" {
  description = "Security group attached to the Kubernetes worker nodes."
  value       = module.eks.node_security_group_id
}
