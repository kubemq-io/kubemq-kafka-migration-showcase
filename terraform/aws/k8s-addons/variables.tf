variable "region" {
  description = "AWS region of the EKS cluster (infra output region)."
  type        = string
}

variable "aws_profile" {
  description = "Named AWS CLI profile. Null means the default credential chain."
  type        = string
  default     = null
  nullable    = true
}

variable "cluster_name" {
  description = "EKS cluster name (infra output cluster_name; default <name_prefix>-eks)."
  type        = string
  default     = "kmq-showcase-eks"
}

variable "storage_class_name" {
  description = "Name of the default gp3 StorageClass to create. Must match the infra root's storage_class output."
  type        = string
  default     = "gp3"
}

variable "demote_gp2_default" {
  description = "Remove the default annotation from the EKS-provided gp2 StorageClass so gp3 is the only default."
  type        = bool
  default     = true
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
