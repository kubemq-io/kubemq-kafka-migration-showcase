variable "name_prefix" {
  description = "Prefix for every resource name created by this module."
  type        = string
  default     = "kmq-showcase"
}

variable "preferred_az" {
  description = "Availability zone for all Kafka VMs. The broker instance type must be offered there (checked at plan time)."
  type        = string
}

variable "vpc_id" {
  description = "VPC that hosts the Kafka VMs."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR. Broker ports 9092-9094 are open to this range (nodes, driver, other brokers)."
  type        = string
}

variable "public_subnet_id" {
  description = "Public subnet (in preferred_az) where brokers and the driver get their network interfaces."
  type        = string
}

variable "public_subnet_cidr" {
  description = "CIDR of public_subnet_id. Fixed private IPs are computed from it so the KRaft voter list is known at plan time."
  type        = string

  validation {
    condition     = can(cidrhost(var.public_subnet_cidr, 20))
    error_message = "public_subnet_cidr must be an IPv4 CIDR with room for at least 21 hosts."
  }
}

variable "operator_cidr" {
  description = "IPv4 CIDR of the operator's laptop (normally a /32). Gets SSH to every VM and Kafka EXTERNAL (9094) to the brokers."
  type        = string

  validation {
    condition     = can(cidrhost(var.operator_cidr, 0)) && var.operator_cidr != "0.0.0.0/0" && tonumber(split("/", var.operator_cidr)[1]) >= 8
    error_message = "operator_cidr must be a valid IPv4 CIDR, not 0.0.0.0/0, and no wider than /8."
  }
}

variable "kafka_version" {
  description = "Apache Kafka version installed on every node (tarball kafka_2.13-<version>.tgz)."
  type        = string
}

variable "kafka_sha512" {
  description = "SHA-512 of the Kafka tarball; bootstrap-node.sh refuses a mismatching download."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{128}$", var.kafka_sha512))
    error_message = "kafka_sha512 must be 128 hex characters."
  }
}

variable "broker_instance_type" {
  description = "EC2 instance type for the 3 brokers. Must carry local NVMe instance storage (i4i family); the first NVMe device is mounted at /mnt/kafka-data."
  type        = string
  default     = "i4i.2xlarge"

  validation {
    condition     = can(regex("^i[3-4]i?[a-z]*\\.", var.broker_instance_type))
    error_message = "broker_instance_type must be an instance-store (i3/i4i family) type so Kafka data lands on local NVMe."
  }
}

variable "driver_instance_type" {
  description = "EC2 instance type for the driver VM (seeder, kcat, verification)."
  type        = string
  default     = "m6i.2xlarge"
}

variable "driver_root_volume_gb" {
  description = "gp3 root volume size of the driver, in GiB."
  type        = number
  default     = 100
}

variable "broker_root_volume_gb" {
  description = "gp3 root volume size of each broker, in GiB (OS + Kafka binaries only; data lives on NVMe)."
  type        = number
  default     = 50
}

variable "use_spot" {
  description = "Accepted for interface parity with the GCP module but IGNORED on AWS: brokers run on i4i instance-store types whose local NVMe is wiped on any interruption, so they are always on-demand."
  type        = bool
  default     = false
}

variable "key_name" {
  description = "Name of an existing aws_key_pair installed on every VM (user ubuntu)."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to the private key matching key_name; used by the readiness gate to SSH to the driver."
  type        = string
}

variable "eks_node_security_group_id" {
  description = "Security group of the Kubernetes worker nodes. When eks_node_ingress_enabled is true a rule allows 9092 and 9094 from it."
  type        = string
  default     = null
  nullable    = true
}

variable "eks_node_ingress_enabled" {
  description = "Create the broker ingress rule for eks_node_security_group_id. Separate from the ID because the ID is unknown until the cluster exists and Terraform cannot count on unknown values."
  type        = bool
  default     = false
}

variable "quorum_timeout_seconds" {
  description = "How long the readiness gate waits for the 3-broker KRaft quorum."
  type        = number
  default     = 600
}

variable "tags" {
  description = "Extra tags merged into every resource (showcase=kafka-migration is always added)."
  type        = map(string)
  default     = {}
}
