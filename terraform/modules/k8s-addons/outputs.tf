output "kubemq_namespace" {
  description = "Namespace KubeMQ is installed into."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "license_secret_name" {
  description = "License Secret name (created here or pre-existing); empty when kmq deploy creates it from a saved credential."
  value       = local.create_license ? kubernetes_secret_v1.license[0].metadata[0].name : (var.existing_license_secret_name != null ? var.existing_license_secret_name : "")
}

output "tls_secret_name" {
  description = "Management TLS Secret name."
  value       = kubernetes_secret_v1.management_tls.metadata[0].name
}

output "tls_ca_cert_pem" {
  description = "Self-signed management certificate (also the CA); pass to kmq --ca-file."
  value       = tls_self_signed_cert.management.cert_pem
}
