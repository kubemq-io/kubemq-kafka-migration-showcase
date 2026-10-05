# AWS infra root: dedicated VPC, 3-broker Kafka cluster + driver VM on EC2,
# EKS cluster with 3 worker nodes. Apply this root first, then
# terraform/aws/k8s-addons.

locals {
  common_tags = { showcase = "kafka-migration" }

  # NAT gateway on-demand list price, rounded. Printed, never enforced.
  hourly_nat_usd = 0.045
}

resource "aws_key_pair" "operator" {
  key_name   = "${var.name_prefix}-operator"
  public_key = file(pathexpand(var.ssh_public_key_path))
  tags       = merge(local.common_tags, { Name = "${var.name_prefix}-operator" })
}

module "network" {
  source = "../../modules/network-aws"

  name_prefix  = var.name_prefix
  vpc_cidr     = var.vpc_cidr
  preferred_az = var.preferred_az
  tags         = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  name_prefix              = var.name_prefix
  cluster_version          = var.kubernetes_version
  vpc_id                   = module.network.vpc_id
  control_plane_subnet_ids = module.network.private_subnet_ids
  node_subnet_ids          = [module.network.node_private_subnet_id]
  operator_cidr            = var.operator_cidr
  admin_principal_arn      = var.admin_principal_arn
  node_instance_type       = var.node_instance_type
  node_count               = 3
  tags                     = local.common_tags
}

module "kafka" {
  source = "../../modules/kafka-aws"

  name_prefix          = var.name_prefix
  preferred_az         = var.preferred_az
  vpc_id               = module.network.vpc_id
  vpc_cidr             = module.network.vpc_cidr
  public_subnet_id     = module.network.kafka_public_subnet_id
  public_subnet_cidr   = module.network.kafka_public_subnet_cidr
  operator_cidr        = var.operator_cidr
  kafka_version        = var.kafka_version
  kafka_sha512         = var.kafka_sha512
  broker_instance_type = var.broker_instance_type
  driver_instance_type = var.driver_instance_type
  use_spot             = var.use_spot
  key_name             = aws_key_pair.operator.key_name
  ssh_private_key_path = var.ssh_private_key_path
  tags                 = local.common_tags

  # Kubernetes nodes (and therefore pods, with the VPC CNI) may reach 9092 and 9094.
  eks_node_ingress_enabled   = true
  eks_node_security_group_id = module.eks.node_security_group_id
}
