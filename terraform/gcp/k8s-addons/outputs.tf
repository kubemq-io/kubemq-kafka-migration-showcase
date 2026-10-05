output "kubemq_namespace" {
  description = "Namespace KubeMQ is installed into."
  value       = module.addons.kubemq_namespace
}

output "license_secret_name" {
  description = "License Secret name for kmq deploy."
  value       = module.addons.license_secret_name
}

output "tls_secret_name" {
  description = "Management TLS Secret name for kmq deploy --tls-secret."
  value       = module.addons.tls_secret_name
}

output "tls_ca_cert_pem" {
  description = "Management certificate PEM for kmq --ca-file."
  value       = module.addons.tls_ca_cert_pem
}
