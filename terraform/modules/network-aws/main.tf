# Dedicated VPC with two public and two private subnets across two availability
# zones. EKS needs two zones for its control plane; Kafka and the worker nodes
# stay in var.preferred_az so no data traffic crosses zones.

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  base_tags = merge({ showcase = "kafka-migration" }, var.tags)

  other_azs = [for az in data.aws_availability_zones.available.names : az if az != var.preferred_az]
  secondary_az = coalesce(
    var.secondary_az,
    length(local.other_azs) > 0 ? local.other_azs[0] : null,
  )

  # Index 0 is always the preferred zone.
  azs = [var.preferred_az, local.secondary_az]

  public_cidrs  = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_cidrs = [for i in range(2) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.base_tags, { Name = "${var.name_prefix}-vpc" })

  lifecycle {
    precondition {
      condition     = contains(data.aws_availability_zones.available.names, var.preferred_az)
      error_message = "preferred_az must be an available zone of the configured region."
    }
    precondition {
      condition     = local.secondary_az != var.preferred_az && contains(data.aws_availability_zones.available.names, local.secondary_az)
      error_message = "secondary_az must be an available zone of the configured region and differ from preferred_az."
    }
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.base_tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.base_tags, {
    Name                     = "${var.name_prefix}-public-${local.azs[count.index]}"
    tier                     = "public"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.base_tags, {
    Name                              = "${var.name_prefix}-private-${local.azs[count.index]}"
    tier                              = "private"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# One NAT gateway in the preferred zone's public subnet. Private nodes use it
# for image pulls and package downloads.
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.base_tags, { Name = "${var.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(local.base_tags, { Name = "${var.name_prefix}-nat" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.base_tags, { Name = "${var.name_prefix}-public" })
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  count = 2

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.base_tags, { Name = "${var.name_prefix}-private" })
}

resource "aws_route" "private_default" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this.id
}

resource "aws_route_table_association" "private" {
  count = 2

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
