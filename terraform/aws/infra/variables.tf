variable "region" {
  description = "AWS region for everything (VPC, Kafka VMs, EKS)."
  type        = string
}

variable "aws_profile" {
  description = "Named AWS CLI profile to use. Null means the default credential chain (env vars, SSO, instance role)."
  type        = string
  default     = null
  nullable    = true
}

variable "preferred_az" {
  description = "Availability zone for the Kafka VMs and the Kubernetes worker nodes, e.g. us-east-1a. i4i.2xlarge must be offered there; Terraform checks and refuses otherwise."
  type        = string
}

variable "operator_cidr" {
  description = "Your laptop's public IPv4 as a CIDR (normally x.x.x.x/32). Opens SSH and Kafka port 9094 on the VMs and the Kubernetes API endpoint. No default on purpose; scripts/operator-cidr.sh writes it to operator.auto.tfvars."
  type        = string

  validation {
    condition     = can(cidrhost(var.operator_cidr, 0))
    error_message = "operator_cidr must be a valid IPv4 CIDR such as 203.0.113.10/32."
  }

  validation {
    condition     = var.operator_cidr != "0.0.0.0/0"
    error_message = "operator_cidr must not be 0.0.0.0/0; that would expose SSH, Kafka and the Kubernetes API to the whole internet."
  }

  validation {
    condition     = tonumber(split("/", var.operator_cidr)[1]) >= 8
    error_message = "operator_cidr prefix must be /8 or narrower (use your /32)."
  }
}

variable "kafka_version" {
  description = "Apache Kafka version (KAFKA_VERSION in versions.env)."
  type        = string
}

variable "kafka_sha512" {
  description = "SHA-512 of kafka_2.13-<kafka_version>.tgz (KAFKA_SHA512 in versions.env)."
  type        = string
}

variable "use_spot" {
  description = "Kept for parity with the GCP root. IGNORED on AWS: the brokers run on i4i instance-store types whose local NVMe is wiped on interruption, so every VM is on-demand. Setting true changes nothing."
  type        = bool
  default     = false
}

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "kmq-showcase"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,24}$", var.name_prefix))
    error_message = "name_prefix must be 2-25 chars, lowercase letters, digits and dashes, starting with a letter."
  }
}

variable "vpc_cidr" {
  description = "CIDR of the dedicated VPC."
  type        = string
  default     = "10.10.0.0/16"
}

variable "broker_instance_type" {
  description = "EC2 type for the 3 Kafka brokers. Must have local NVMe instance storage."
  type        = string
  default     = "i4i.2xlarge"
}

variable "driver_instance_type" {
  description = "EC2 type for the Kafka driver VM."
  type        = string
  default     = "m6i.2xlarge"
}

variable "node_instance_type" {
  description = "EC2 type for the 3 Kubernetes worker nodes."
  type        = string
  default     = "m6i.xlarge"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.34"
}

variable "admin_principal_arn" {
  description = "IAM principal that gets cluster-admin on EKS. Null = the identity running Terraform."
  type        = string
  default     = null
  nullable    = true
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key uploaded as the EC2 key pair (user ubuntu on every VM)."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_path" {
  description = "Path to the matching SSH private key; used by the Kafka readiness gate and printed in driver_ssh_command."
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "kubemq_namespace" {
  description = "Namespace KubeMQ will be installed into (created by the k8s-addons root). Exported for scripts/write-env.sh."
  type        = string
  default     = "kubemq"
}
