variable "project_id" {
  description = "GCP project id that will own every resource."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{4,28}[a-z0-9]$", var.project_id))
    error_message = "project_id must be a valid GCP project id."
  }
}

variable "region" {
  description = "GCP region (for example europe-west1)."
  type        = string
}

variable "zone" {
  description = "GCP zone inside region for Kafka VMs and GKE nodes (for example europe-west1-b)."
  type        = string

  validation {
    condition     = can(regex("^[a-z]+-[a-z]+[0-9]-[a-z]$", var.zone))
    error_message = "zone must look like <region>-<letter>."
  }
}

variable "operator_cidr" {
  description = "Your public IPv4 as a /32 (scripts/operator-cidr.sh writes operator.auto.tfvars). Only this CIDR may reach SSH, Kafka 9094 and the Kubernetes API."
  type        = string

  validation {
    condition     = can(cidrhost(var.operator_cidr, 0)) && var.operator_cidr != "0.0.0.0/0" && tonumber(split("/", var.operator_cidr)[1]) >= 8
    error_message = "operator_cidr must be an IPv4 CIDR, not 0.0.0.0/0, and no wider than /8."
  }
}

variable "kafka_version" {
  description = "Apache Kafka version (keep in sync with versions.env)."
  type        = string
  default     = "4.3.1"
}

variable "kafka_sha512" {
  description = "SHA-512 of kafka_2.13-<kafka_version>.tgz (from versions.env)."
  type        = string
}

variable "use_spot" {
  description = "Run Kafka VMs as Spot. Cheaper, but preemption wipes local SSD data (re-seed)."
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "kmq-showcase"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,20}$", var.name_prefix))
    error_message = "name_prefix must be lowercase letters, digits, dashes; at most 21 characters."
  }
}

variable "broker_machine_type" {
  description = "Machine type for the 3 Kafka brokers and the driver."
  type        = string
  default     = "n2-standard-8"
}

variable "node_machine_type" {
  description = "Machine type for GKE nodes."
  type        = string
  default     = "n2-standard-4"
}

variable "gke_regional" {
  description = "Regional GKE control plane instead of zonal."
  type        = bool
  default     = false
}

variable "ssh_user" {
  description = "SSH user on the Kafka VMs. Empty: let gcloud choose."
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  description = "Public key to install for ssh_user. Empty: use gcloud compute ssh instead of plain ssh."
  type        = string
  default     = ""

  validation {
    condition     = var.ssh_public_key_path == "" || can(regex("\\.pub$", var.ssh_public_key_path))
    error_message = "ssh_public_key_path must end in .pub (the private key is derived by dropping .pub)."
  }
}

variable "kubemq_namespace" {
  description = "Namespace KubeMQ will be installed into (used by the k8s-addons root and kmq deploy)."
  type        = string
  default     = "kubemq"
}

variable "subnet_cidr" {
  description = "Primary subnet CIDR."
  type        = string
  default     = "10.10.0.0/20"
}

variable "pods_cidr" {
  description = "GKE pods secondary range."
  type        = string
  default     = "10.20.0.0/14"
}

variable "services_cidr" {
  description = "GKE services secondary range."
  type        = string
  default     = "10.24.0.0/20"
}
