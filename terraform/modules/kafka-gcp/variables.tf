variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "kmq-showcase"
}

variable "project_id" {
  description = "GCP project id (used by the readiness gate's gcloud ssh)."
  type        = string
}

variable "region" {
  description = "GCP region of the static addresses."
  type        = string
}

variable "zone" {
  description = "GCP zone for all Kafka VMs."
  type        = string
}

variable "network_self_link" {
  description = "VPC self link."
  type        = string
}

variable "subnet_self_link" {
  description = "Subnet self link the VMs attach to."
  type        = string
}

variable "subnet_cidr" {
  description = "Primary CIDR of the subnet; allowed to reach 9092/9093/9094."
  type        = string
}

variable "pod_cidr" {
  description = "Kubernetes pod CIDR; allowed to reach 9092/9094 only."
  type        = string
}

variable "operator_cidr" {
  description = "Operator IPv4 CIDR (normally a /32); allowed to reach 22 and 9094."
  type        = string

  validation {
    condition     = can(cidrhost(var.operator_cidr, 0)) && var.operator_cidr != "0.0.0.0/0" && tonumber(split("/", var.operator_cidr)[1]) >= 8
    error_message = "operator_cidr must be an IPv4 CIDR, not 0.0.0.0/0, and no wider than /8."
  }
}

variable "kafka_version" {
  description = "Apache Kafka version to install (Scala 2.13 build)."
  type        = string
}

variable "kafka_sha512" {
  description = "SHA-512 of the Kafka tarball kafka_2.13-<version>.tgz."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{128}$", var.kafka_sha512))
    error_message = "kafka_sha512 must be 128 hex characters."
  }
}

variable "broker_machine_type" {
  description = "Machine type for the 3 brokers."
  type        = string
  default     = "n2-standard-8"
}

variable "driver_machine_type" {
  description = "Machine type for the driver VM."
  type        = string
  default     = "n2-standard-8"
}

variable "image" {
  description = "Boot image for all VMs."
  type        = string
  default     = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
}

variable "use_spot" {
  description = "Run brokers and driver as Spot VMs (cheaper; may be preempted, which loses local SSD data)."
  type        = bool
  default     = false
}

variable "nvme_model_regex" {
  description = "Regex matched against the NVMe model string to find the local SSD."
  type        = string
  default     = "nvme_card$"
}

variable "ssh_user" {
  description = "SSH user for the driver. Empty means: let gcloud pick the user."
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  description = "Path to an SSH public key added to all VMs for ssh_user. Empty means: use gcloud compute ssh (OS Login / project keys)."
  type        = string
  default     = ""
}

variable "readiness_timeout_seconds" {
  description = "How long the readiness gate waits for the Kafka quorum."
  type        = number
  default     = 600
}

variable "labels" {
  description = "Extra labels merged into every labelled resource."
  type        = map(string)
  default     = {}
}
