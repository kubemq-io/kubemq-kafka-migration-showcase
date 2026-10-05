variable "name_prefix" {
  description = "Prefix for the cluster name and every IAM role created here."
  type        = string
  default     = "kmq-showcase"
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS control plane and node group."
  type        = string
  default     = "1.34"

  validation {
    condition     = can(regex("^1\\.(2[6-9]|[3-9][0-9])$", var.cluster_version))
    error_message = "cluster_version must be 1.26 or newer (access entries and Pod Identity require it)."
  }
}

variable "vpc_id" {
  description = "VPC that hosts the cluster."
  type        = string
}

variable "control_plane_subnet_ids" {
  description = "Private subnets in at least two availability zones for the EKS control plane network interfaces."
  type        = list(string)

  validation {
    condition     = length(var.control_plane_subnet_ids) >= 2
    error_message = "EKS needs subnets in at least two availability zones."
  }
}

variable "node_subnet_ids" {
  description = "Private subnet(s) for the managed node group; normally the single private subnet of the preferred zone."
  type        = list(string)

  validation {
    condition     = length(var.node_subnet_ids) >= 1
    error_message = "At least one node subnet is required."
  }
}

variable "operator_cidr" {
  description = "IPv4 CIDR allowed to reach the public Kubernetes API endpoint."
  type        = string

  validation {
    condition     = can(cidrhost(var.operator_cidr, 0)) && var.operator_cidr != "0.0.0.0/0" && tonumber(split("/", var.operator_cidr)[1]) >= 8
    error_message = "operator_cidr must be a valid IPv4 CIDR, not 0.0.0.0/0, and no wider than /8."
  }
}

variable "admin_principal_arn" {
  description = "IAM principal granted AmazonEKSClusterAdminPolicy through an access entry. Default: the identity running Terraform (assumed-role session ARNs are normalised to the role ARN)."
  type        = string
  default     = null
  nullable    = true
}

variable "node_instance_type" {
  description = "EC2 instance type of the worker nodes."
  type        = string
  default     = "m6i.xlarge"
}

variable "node_count" {
  description = "Number of worker nodes (min = max = desired)."
  type        = number
  default     = 3
}

variable "node_disk_gb" {
  description = "Root volume size of each worker node, in GiB."
  type        = number
  default     = 50
}

variable "tags" {
  description = "Extra tags merged into every resource (showcase=kafka-migration is always added)."
  type        = map(string)
  default     = {}
}
