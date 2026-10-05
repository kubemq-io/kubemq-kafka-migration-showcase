locals {
  labels          = merge({ showcase = "kafka-migration" }, var.labels)
  create_license  = nonsensitive(var.license_key != null)
  tls_secret_name = var.tls_secret_name != "" ? var.tls_secret_name : "${var.release_name}-management-tls"

  # Every name kmq's in-cluster worker and the operator laptop dial.
  tls_dns_names = concat(
    [
      "${var.release_name}-api.${var.namespace}.svc",
      "${var.release_name}-api.${var.namespace}.svc.cluster.local",
      "*.${var.release_name}.${var.namespace}.svc",
      "*.${var.release_name}.${var.namespace}.svc.cluster.local",
      "localhost",
    ],
    [for n in range(var.server_count) : "${var.release_name}-${n}.${var.release_name}.${var.namespace}.svc.cluster.local"],
  )
}

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name   = var.namespace
    labels = local.labels
  }

  lifecycle {
    precondition {
      condition     = !(var.license_key != null && var.existing_license_secret_name != null)
      error_message = "Set at most one of license_key or existing_license_secret_name (leave both null when kmq deploy will create the Secret from a saved kmq license credential)."
    }
  }
}

resource "kubernetes_secret_v1" "license" {
  count = local.create_license ? 1 : 0

  metadata {
    name      = var.license_secret_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }

  type = "Opaque"
  data = {
    licenseKey = var.license_key
  }
}

resource "tls_private_key" "management" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "management" {
  private_key_pem       = tls_private_key.management.private_key_pem
  validity_period_hours = var.tls_validity_hours
  early_renewal_hours   = 168
  dns_names             = local.tls_dns_names
  ip_addresses          = ["127.0.0.1"]

  subject {
    common_name  = "${var.release_name}-api.${var.namespace}.svc"
    organization = "kubemq-kafka-migration-showcase"
  }

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
    "client_auth",
  ]
}

resource "kubernetes_secret_v1" "management_tls" {
  metadata {
    name      = local.tls_secret_name
    namespace = kubernetes_namespace_v1.this.metadata[0].name
    labels    = local.labels
  }

  type = "kubernetes.io/tls"
  data = {
    "tls.crt" = tls_self_signed_cert.management.cert_pem
    "tls.key" = tls_private_key.management.private_key_pem
  }
}
