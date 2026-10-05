variable "project_id" {
  description = "GCP project id (same as the infra root)."
  type        = string
}

variable "cluster_name" {
  description = "GKE cluster name (infra output cluster_name; default <name_prefix>-gke)."
  type        = string
  default     = "kmq-showcase-gke"
}

variable "cluster_location" {
  description = "GKE cluster zone or region (infra output cluster_location)."
  type        = string
}

variable "kubemq_namespace" {
  description = "Namespace to create for KubeMQ."
  type        = string
  default     = "kubemq"
}

variable "kubemq_release_name" {
  description = "KubeMQ installation name used by kmq deploy; drives TLS SANs."
  type        = string
  default     = "kubemq"
}

variable "kubemq_license_key" {
  description = "KubeMQ license key. Set this OR kubemq_license_secret_name."
  type        = string
  default     = null
  sensitive   = true
}

variable "kubemq_license_secret_name" {
  description = "Pre-created license Secret name in the namespace (key \"licenseKey\"). Set this OR kubemq_license_key."
  type        = string
  default     = null
}
