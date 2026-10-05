variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "kmq-showcase"
}

variable "project_id" {
  description = "GCP project id."
  type        = string
}

variable "region" {
  description = "GCP region."
  type        = string
}

variable "zone" {
  description = "GCP zone. Zonal clusters live here; regional clusters place their nodes here."
  type        = string
}

variable "regional" {
  description = "Create a regional (multi-master) cluster instead of a zonal one."
  type        = bool
  default     = false
}

variable "network_self_link" {
  description = "VPC self link."
  type        = string
}

variable "subnet_self_link" {
  description = "Subnet self link."
  type        = string
}

variable "pods_range_name" {
  description = "Secondary range name for pods."
  type        = string
  default     = "pods"
}

variable "services_range_name" {
  description = "Secondary range name for services."
  type        = string
  default     = "services"
}

variable "master_ipv4_cidr" {
  description = "Private /28 for the GKE control plane."
  type        = string
  default     = "172.16.0.0/28"
}

variable "operator_cidr" {
  description = "Only this IPv4 CIDR may reach the Kubernetes API."
  type        = string

  validation {
    condition     = can(cidrhost(var.operator_cidr, 0)) && var.operator_cidr != "0.0.0.0/0" && tonumber(split("/", var.operator_cidr)[1]) >= 8
    error_message = "operator_cidr must be an IPv4 CIDR, not 0.0.0.0/0, and no wider than /8."
  }
}

variable "node_machine_type" {
  description = "Machine type for the node pool."
  type        = string
  default     = "n2-standard-4"
}

variable "node_count" {
  description = "Number of nodes in the pool."
  type        = number
  default     = 3
}

variable "node_disk_size_gb" {
  description = "Boot disk size per node."
  type        = number
  default     = 100
}

variable "labels" {
  description = "Extra labels merged into every labelled resource."
  type        = map(string)
  default     = {}
}
