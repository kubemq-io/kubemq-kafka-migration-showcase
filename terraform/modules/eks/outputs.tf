output "cluster_name" {
  description = "EKS cluster name."
  value       = aws_eks_cluster.this.name
}

output "cluster_arn" {
  description = "EKS cluster ARN."
  value       = aws_eks_cluster.this.arn
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_version" {
  description = "Kubernetes version actually running."
  value       = aws_eks_cluster.this.version
}

output "node_security_group_id" {
  description = "EKS-managed cluster security group; attached to every managed node, so pod traffic (VPC CNI) carries it."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "node_role_arn" {
  description = "IAM role of the worker nodes."
  value       = aws_iam_role.node.arn
}

output "admin_principal_arn" {
  description = "IAM principal granted cluster admin through the access entry."
  value       = local.admin_principal_arn
}

output "kubeconfig_command" {
  description = "Command that writes kubeconfig for this cluster."
  value       = "aws eks update-kubeconfig --name ${aws_eks_cluster.this.name} --region ${data.aws_region.current.name}"
}

output "storage_class" {
  description = "Name of the default StorageClass the k8s-addons root creates (EBS CSI, gp3). String only; the object is created in terraform/aws/k8s-addons."
  value       = "gp3"
}

output "ebs_csi_addon_ready" {
  description = "ID of the EBS CSI add-on; depend on it before creating StorageClasses."
  value       = aws_eks_addon.ebs_csi.id
}

output "hourly_cost_estimate" {
  description = "Static on-demand list-price estimate for the control plane and worker nodes."
  value       = format("USD %.2f/h on-demand (estimate: EKS control plane + %dx %s)", local.hourly_total, var.node_count, var.node_instance_type)
}

output "hourly_cost_usd" {
  description = "Numeric form of hourly_cost_estimate, for roots that sum several modules."
  value       = local.hourly_total
}
