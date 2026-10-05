variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "kmq-showcase"
}

variable "region" {
  description = "GCP region for the subnet, router and NAT."
  type        = string
}

variable "primary_cidr" {
  description = "Primary CIDR of the subnet (VM addresses, GKE nodes)."
  type        = string
  default     = "10.10.0.0/20"

  validation {
    condition     = can(cidrhost(var.primary_cidr, 0))
    error_message = "primary_cidr must be a valid IPv4 CIDR."
  }
}

variable "pods_cidr" {
  description = "Secondary range \"pods\" used by GKE for pod addresses."
  type        = string
  default     = "10.20.0.0/14"

  validation {
    condition     = can(cidrhost(var.pods_cidr, 0))
    error_message = "pods_cidr must be a valid IPv4 CIDR."
  }
}

variable "services_cidr" {
  description = "Secondary range \"services\" used by GKE for ClusterIP addresses."
  type        = string
  default     = "10.24.0.0/20"

  validation {
    condition     = can(cidrhost(var.services_cidr, 0))
    error_message = "services_cidr must be a valid IPv4 CIDR."
  }
}
