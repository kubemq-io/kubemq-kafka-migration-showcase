output "kafka_bootstrap_external" {
  description = "Comma-separated external bootstrap servers (port 9094)."
  value       = join(",", [for k in sort(tolist(local.brokers)) : "${local.broker_external_ips[k]}:9094"])
}

output "kafka_bootstrap_internal" {
  description = "Comma-separated internal bootstrap servers (port 9092)."
  value       = join(",", [for k in sort(tolist(local.brokers)) : "${local.broker_internal_ips[k]}:9092"])
}

output "broker_internal_ips" {
  description = "Broker id -> internal IP."
  value       = local.broker_internal_ips
}

output "broker_external_ips" {
  description = "Broker id -> external IP."
  value       = local.broker_external_ips
}

output "driver_public_ip" {
  description = "External IP of the driver VM."
  value       = google_compute_address.driver_external.address
}

output "driver_internal_ip" {
  description = "Internal IP of the driver VM."
  value       = google_compute_address.driver_internal.address
}

output "driver_name" {
  description = "Instance name of the driver VM."
  value       = google_compute_instance.driver.name
}

output "driver_ssh_command" {
  description = "Command that opens a shell on the driver."
  value       = local.driver_ssh_command
}

output "cluster_id" {
  description = "KRaft cluster id shared by all brokers."
  value       = local.cluster_id
}

output "hourly_cost_estimate" {
  description = "Static on-demand estimate for 4x n2-standard-8 plus 3 local SSDs."
  value       = var.use_spot ? "about USD 0.70/h spot (estimate; preemptible)" : "about USD 1.80/h on-demand (estimate: 4x n2-standard-8 at ~USD 0.39/h + 3x 375GB local SSD at ~USD 0.08/h)"
}

output "ready" {
  description = "Depends on the readiness gate; use for ordering."
  value       = null_resource.kafka_ready.id
}
