# 3 Apache Kafka (KRaft) brokers on instance-store NVMe plus 1 driver VM, all in
# one public subnet of the preferred zone. Private IPs are fixed at plan time so
# the voter list and advertised listeners can be rendered into cloud-init.

locals {
  base_tags = merge({ showcase = "kafka-migration" }, var.tags)

  broker_ids = [1, 2, 3]

  # .11 .12 .13 for brokers, .20 for the driver (AWS reserves .0-.3 and the last address).
  broker_private_ips = { for id in local.broker_ids : tostring(id) => cidrhost(var.public_subnet_cidr, 10 + id) }
  driver_private_ip  = cidrhost(var.public_subnet_cidr, 20)

  voters = join(",", [for id in local.broker_ids : "${id}@${local.broker_private_ips[tostring(id)]}:9093"])

  nvme_model_regex = "Amazon EC2 NVMe Instance Storage"

  # KRaft cluster id: 22-char base64url of 16 random bytes. kafka-storage.sh takes it as
  # "-t <id>"; an id that begins with "-" is parsed as a flag, so that first character is
  # rewritten (still 16 bytes, still base64url).
  cluster_id = startswith(random_id.cluster.b64_url, "-") ? "A${substr(random_id.cluster.b64_url, 1, 21)}" : random_id.cluster.b64_url

  # On-demand us-east-1 list prices, rounded. Printed, never enforced.
  hourly_broker = 0.69
  hourly_driver = 0.38
  hourly_eip    = 0.005
  hourly_total  = 3 * local.hourly_broker + local.hourly_driver + 4 * local.hourly_eip
}

data "aws_ec2_instance_type_offerings" "broker" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.broker_instance_type]
  }

  filter {
    name   = "location"
    values = [var.preferred_az]
  }
}

data "aws_ec2_instance_type_offerings" "driver" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.driver_instance_type]
  }

  filter {
    name   = "location"
    values = [var.preferred_az]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# One cluster id shared by all brokers. configure-broker.sh formats a broker
# only when meta.properties is absent and refuses a different id.
resource "random_id" "cluster" {
  byte_length = 16
}

# ---------------------------------------------------------------------------
# Security groups. Rules are separate resources so a change replaces the rule
# instead of appending to an inline list.
# ---------------------------------------------------------------------------

resource "aws_security_group" "brokers" {
  name        = "${var.name_prefix}-kafka-brokers"
  description = "Kafka brokers: 9092-9094 inside the VPC, 22 and 9094 from the operator"
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-brokers", role = "broker" })
}

resource "aws_vpc_security_group_ingress_rule" "brokers_self" {
  security_group_id            = aws_security_group.brokers.id
  description                  = "Broker to broker (listeners + controller)"
  referenced_security_group_id = aws_security_group.brokers.id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9094
  tags                         = local.base_tags
}

resource "aws_vpc_security_group_ingress_rule" "brokers_vpc" {
  # 9092 (INTERNAL) and 9094 (EXTERNAL) only; the controller port 9093 stays broker-to-broker.
  for_each = toset(["9092", "9094"])

  security_group_id = aws_security_group.brokers.id
  description       = "Kafka listener ${each.value} from the VPC (driver, Kubernetes nodes and pods)"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
  tags              = local.base_tags
}

resource "aws_vpc_security_group_ingress_rule" "brokers_operator_ssh" {
  security_group_id = aws_security_group.brokers.id
  description       = "SSH from the operator"
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  tags              = local.base_tags
}

resource "aws_vpc_security_group_ingress_rule" "brokers_operator_external" {
  security_group_id = aws_security_group.brokers.id
  description       = "Kafka EXTERNAL listener from the operator"
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "tcp"
  from_port         = 9094
  to_port           = 9094
  tags              = local.base_tags
}

resource "aws_vpc_security_group_ingress_rule" "brokers_eks_nodes" {
  # 9092 (INTERNAL) and 9094 (EXTERNAL) only; the controller port 9093 stays broker-to-broker.
  for_each = var.eks_node_ingress_enabled ? toset(["9092", "9094"]) : toset([])

  security_group_id            = aws_security_group.brokers.id
  description                  = "Kafka listener ${each.value} from Kubernetes nodes"
  referenced_security_group_id = var.eks_node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  tags                         = local.base_tags

  lifecycle {
    precondition {
      condition     = var.eks_node_security_group_id != null
      error_message = "eks_node_security_group_id must be set when eks_node_ingress_enabled is true."
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "brokers_all" {
  security_group_id = aws_security_group.brokers.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  tags              = local.base_tags
}

resource "aws_security_group" "driver" {
  name        = "${var.name_prefix}-kafka-driver"
  description = "Kafka driver VM: SSH from the operator, anything from the brokers"
  vpc_id      = var.vpc_id

  tags = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-driver", role = "driver" })
}

resource "aws_vpc_security_group_ingress_rule" "driver_operator_ssh" {
  security_group_id = aws_security_group.driver.id
  description       = "SSH from the operator"
  cidr_ipv4         = var.operator_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  tags              = local.base_tags
}

resource "aws_vpc_security_group_ingress_rule" "driver_from_brokers" {
  security_group_id            = aws_security_group.driver.id
  description                  = "Anything from the brokers"
  referenced_security_group_id = aws_security_group.brokers.id
  ip_protocol                  = "-1"
  tags                         = local.base_tags
}

resource "aws_vpc_security_group_egress_rule" "driver_all" {
  security_group_id = aws_security_group.driver.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  tags              = local.base_tags
}

# ---------------------------------------------------------------------------
# Addresses first: fixed private IPs on pre-created interfaces, one EIP each.
# ---------------------------------------------------------------------------

resource "aws_network_interface" "broker" {
  for_each = local.broker_private_ips

  subnet_id       = var.public_subnet_id
  private_ips     = [each.value]
  security_groups = [aws_security_group.brokers.id]

  tags = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-${each.key}", role = "broker" })
}

resource "aws_network_interface" "driver" {
  subnet_id       = var.public_subnet_id
  private_ips     = [local.driver_private_ip]
  security_groups = [aws_security_group.driver.id]

  tags = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-driver", role = "driver" })
}

resource "aws_eip" "broker" {
  for_each = local.broker_private_ips

  domain = "vpc"
  tags   = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-${each.key}", role = "broker" })
}

resource "aws_eip" "driver" {
  domain = "vpc"
  tags   = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-driver", role = "driver" })
}

resource "aws_eip_association" "broker" {
  for_each = local.broker_private_ips

  allocation_id        = aws_eip.broker[each.key].id
  network_interface_id = aws_network_interface.broker[each.key].id
  private_ip_address   = each.value
}

resource "aws_eip_association" "driver" {
  allocation_id        = aws_eip.driver.id
  network_interface_id = aws_network_interface.driver.id
  private_ip_address   = local.driver_private_ip
}

# ---------------------------------------------------------------------------
# cloud-init. Scripts are shipped verbatim from scripts/kafka/ and run on every
# boot by a systemd oneshot. user_data is gzip-compressed to stay under the
# 16 KiB EC2 limit.
# ---------------------------------------------------------------------------

locals {
  bootstrap_node_script   = file("${path.module}/../../../scripts/kafka/bootstrap-node.sh")
  configure_broker_script = file("${path.module}/../../../scripts/kafka/configure-broker.sh")

  broker_user_data = {
    for id in local.broker_ids : tostring(id) => templatefile("${path.module}/cloud-init.yaml.tftpl", {
      role                 = "broker"
      node_id              = id
      cluster_id           = local.cluster_id
      internal_ip          = local.broker_private_ips[tostring(id)]
      external_ip          = aws_eip.broker[tostring(id)].public_ip
      voters               = local.voters
      kafka_version        = var.kafka_version
      kafka_sha512         = var.kafka_sha512
      nvme_model_regex     = local.nvme_model_regex
      mount_nvme           = 1
      bootstrap_node_b64   = base64encode(local.bootstrap_node_script)
      configure_broker_b64 = base64encode(local.configure_broker_script)
    })
  }

  driver_user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    role                 = "driver"
    node_id              = 0
    cluster_id           = local.cluster_id
    internal_ip          = local.driver_private_ip
    external_ip          = aws_eip.driver.public_ip
    voters               = local.voters
    kafka_version        = var.kafka_version
    kafka_sha512         = var.kafka_sha512
    nvme_model_regex     = local.nvme_model_regex
    mount_nvme           = 0
    bootstrap_node_b64   = base64encode(local.bootstrap_node_script)
    configure_broker_b64 = base64encode(local.configure_broker_script)
  })
}

resource "aws_instance" "broker" {
  for_each = local.broker_private_ips

  ami               = data.aws_ami.ubuntu.id
  instance_type     = var.broker_instance_type
  availability_zone = var.preferred_az
  key_name          = var.key_name

  network_interface {
    network_interface_id = aws_network_interface.broker[each.key].id
    device_index         = 0
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.broker_root_volume_gb
    delete_on_termination = true
    tags                  = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-${each.key}-root", role = "broker" })
  }

  metadata_options {
    http_tokens = "required"
  }

  user_data_base64            = base64gzip(local.broker_user_data[each.key])
  user_data_replace_on_change = false

  tags = merge(local.base_tags, {
    Name    = "${var.name_prefix}-kafka-${each.key}"
    role    = "broker"
    node_id = each.key
  })

  lifecycle {
    # A replaced broker loses its NVMe data; never replace on image, script or key-pair drift
    # (key_name forces replacement on aws_instance).
    ignore_changes = [ami, user_data, user_data_base64, key_name]

    precondition {
      condition     = contains(data.aws_ec2_instance_type_offerings.broker.instance_types, var.broker_instance_type)
      error_message = "Instance type ${var.broker_instance_type} is not offered in ${var.preferred_az}. Pick another preferred_az (aws ec2 describe-instance-type-offerings --location-type availability-zone --filters Name=instance-type,Values=${var.broker_instance_type})."
    }
  }

  depends_on = [aws_eip_association.broker]
}

resource "aws_instance" "driver" {
  ami               = data.aws_ami.ubuntu.id
  instance_type     = var.driver_instance_type
  availability_zone = var.preferred_az
  key_name          = var.key_name

  network_interface {
    network_interface_id = aws_network_interface.driver.id
    device_index         = 0
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.driver_root_volume_gb
    delete_on_termination = true
    tags                  = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-driver-root", role = "driver" })
  }

  metadata_options {
    http_tokens = "required"
  }

  user_data_base64            = base64gzip(local.driver_user_data)
  user_data_replace_on_change = false

  tags = merge(local.base_tags, { Name = "${var.name_prefix}-kafka-driver", role = "driver" })

  lifecycle {
    ignore_changes = [ami, user_data, user_data_base64]

    precondition {
      condition     = contains(data.aws_ec2_instance_type_offerings.driver.instance_types, var.driver_instance_type)
      error_message = "Instance type ${var.driver_instance_type} is not offered in ${var.preferred_az}."
    }
  }

  depends_on = [aws_eip_association.driver]
}

# ---------------------------------------------------------------------------
# Readiness gate: SSH to the driver and wait for a 3-broker quorum.
# ---------------------------------------------------------------------------

resource "null_resource" "quorum_ready" {
  triggers = {
    driver_instance = aws_instance.driver.id
    brokers         = join(",", [for b in aws_instance.broker : b.id])
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "${path.module}/wait-for-quorum.sh"

    environment = {
      DRIVER_IP        = aws_eip.driver.public_ip
      SSH_KEY          = pathexpand(var.ssh_private_key_path)
      BOOTSTRAP        = join(",", [for id in local.broker_ids : "${local.broker_private_ips[tostring(id)]}:9092"])
      EXPECTED_BROKERS = "3"
      TIMEOUT_SECONDS  = tostring(var.quorum_timeout_seconds)
    }
  }

  depends_on = [aws_instance.broker, aws_instance.driver]
}
