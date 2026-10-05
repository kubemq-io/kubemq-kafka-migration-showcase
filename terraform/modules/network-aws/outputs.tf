output "vpc_id" {
  description = "ID of the dedicated VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 CIDR of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "availability_zones" {
  description = "The two zones in use; index 0 is the preferred zone."
  value       = local.azs
}

output "preferred_az" {
  description = "Zone that hosts Kafka and the Kubernetes worker nodes."
  value       = var.preferred_az
}

output "public_subnet_ids" {
  description = "Public subnet IDs, ordered like availability_zones."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs, ordered like availability_zones."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids_by_az" {
  description = "Map availability zone -> public subnet ID."
  value       = { for i, az in local.azs : az => aws_subnet.public[i].id }
}

output "private_subnet_ids_by_az" {
  description = "Map availability zone -> private subnet ID."
  value       = { for i, az in local.azs : az => aws_subnet.private[i].id }
}

output "kafka_public_subnet_id" {
  description = "Public subnet in the preferred zone; the Kafka VMs live here."
  value       = aws_subnet.public[0].id
}

output "kafka_public_subnet_cidr" {
  description = "CIDR of the Kafka public subnet (used to compute fixed private IPs)."
  value       = aws_subnet.public[0].cidr_block
}

output "node_private_subnet_id" {
  description = "Private subnet in the preferred zone; the Kubernetes worker nodes live here."
  value       = aws_subnet.private[0].id
}

output "nat_gateway_id" {
  description = "ID of the single NAT gateway."
  value       = aws_nat_gateway.this.id
}
