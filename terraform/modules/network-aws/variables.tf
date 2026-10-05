variable "name_prefix" {
  description = "Prefix for every resource name created by this module."
  type        = string
  default     = "kmq-showcase"
}

variable "vpc_cidr" {
  description = "IPv4 CIDR of the dedicated VPC. Public subnets take /24 blocks 0-1, private subnets /24 blocks 10-11."
  type        = string
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a prefix of /20 or wider (four /24 subnets are carved from it)."
  }
}

variable "preferred_az" {
  description = "Availability zone that hosts the Kafka VMs and the Kubernetes worker nodes (keeps all data traffic in one zone). Must belong to the provider region."
  type        = string
}

variable "secondary_az" {
  description = "Second availability zone, required by the EKS control plane. When null the first other zone reported by the region is used."
  type        = string
  default     = null
}

variable "tags" {
  description = "Extra tags merged into every resource (showcase=kafka-migration is always added)."
  type        = map(string)
  default     = {}
}
