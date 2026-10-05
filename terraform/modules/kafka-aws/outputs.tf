output "kafka_bootstrap_external" {
  description = "Comma-separated EXTERNAL listener addresses (public IP:9094) of the 3 brokers; reachable only from operator_cidr."
  value       = join(",", [for id in local.broker_ids : "${aws_eip.broker[tostring(id)].public_ip}:9094"])
}

output "kafka_bootstrap_internal" {
  description = "Comma-separated INTERNAL listener addresses (private IP:9092) of the 3 brokers; reachable inside the VPC."
  value       = join(",", [for id in local.broker_ids : "${local.broker_private_ips[tostring(id)]}:9092"])
}

output "broker_private_ips" {
  description = "Map broker node id -> fixed private IP."
  value       = local.broker_private_ips
}

output "broker_public_ips" {
  description = "Map broker node id -> elastic IP."
  value       = { for id, eip in aws_eip.broker : id => eip.public_ip }
}

output "driver_public_ip" {
  description = "Elastic IP of the driver VM."
  value       = aws_eip.driver.public_ip
}

output "driver_private_ip" {
  description = "Fixed private IP of the driver VM."
  value       = local.driver_private_ip
}

output "driver_ssh_command" {
  description = "SSH command for the driver VM."
  value       = "ssh -i ${pathexpand(var.ssh_private_key_path)} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${aws_eip.driver.public_ip}"
}

output "cluster_id" {
  description = "KRaft cluster id shared by all brokers."
  value       = local.cluster_id
}

output "brokers_security_group_id" {
  description = "Security group attached to the brokers."
  value       = aws_security_group.brokers.id
}

output "driver_security_group_id" {
  description = "Security group attached to the driver."
  value       = aws_security_group.driver.id
}

output "hourly_cost_estimate" {
  description = "Static on-demand list-price estimate for the Kafka VMs and elastic IPs."
  value       = format("USD %.2f/h on-demand (estimate: 3x %s + 1x %s + 4 elastic IPs)", local.hourly_total, var.broker_instance_type, var.driver_instance_type)
}

output "quorum_ready_id" {
  description = "Changes when the readiness gate re-runs; depend on it to sequence work after Kafka is up."
  value       = null_resource.quorum_ready.id
}

output "hourly_cost_usd" {
  description = "Numeric form of hourly_cost_estimate, for roots that sum several modules."
  value       = local.hourly_total
}
