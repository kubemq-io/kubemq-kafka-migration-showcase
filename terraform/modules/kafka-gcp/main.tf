locals {
  brokers    = toset(["1", "2", "3"])
  labels     = merge({ showcase = "kafka-migration" }, var.labels)
  use_gcloud = var.ssh_public_key_path == ""
  ssh_pubkey = local.use_gcloud ? "" : trimspace(file(pathexpand(var.ssh_public_key_path)))

  # KRaft cluster id: 22-char base64url of 16 random bytes. kafka-storage.sh takes it as
  # "-t <id>"; an id that begins with "-" is parsed as a flag, so that first character is
  # rewritten (still 16 bytes, still base64url).
  cluster_id = startswith(random_id.cluster.b64_url, "-") ? "A${substr(random_id.cluster.b64_url, 1, 21)}" : random_id.cluster.b64_url

  broker_internal_ips = { for k, a in google_compute_address.broker_internal : k => a.address }
  broker_external_ips = { for k, a in google_compute_address.broker_external : k => a.address }

  voters = join(",", [for k in sort(tolist(local.brokers)) : "${k}@${local.broker_internal_ips[k]}:9093"])

  bootstrap_script = file("${path.module}/../../../scripts/kafka/bootstrap-node.sh")
  configure_script = file("${path.module}/../../../scripts/kafka/configure-broker.sh")

  driver_name = "${var.name_prefix}-kafka-driver"

  # gcloud needs user@instance when ssh_user is set.
  gcloud_target = var.ssh_user == "" ? local.driver_name : "${var.ssh_user}@${local.driver_name}"
  driver_ssh_command = local.use_gcloud ? (
    "gcloud compute ssh ${local.gcloud_target} --zone ${var.zone} --project ${var.project_id} --quiet"
    ) : (
    "ssh -i ${replace(pathexpand(var.ssh_public_key_path), "/\\.pub$/", "")} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ${var.ssh_user}@${google_compute_address.driver_external.address}"
  )
}

# One KRaft cluster id shared by all brokers; configure-broker refuses any other id.
resource "random_id" "cluster" {
  byte_length = 16
}

# Addresses are created first so voters and advertised listeners are known at plan time.
resource "google_compute_address" "broker_internal" {
  for_each     = local.brokers
  name         = "${var.name_prefix}-kafka-${each.key}-int"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = var.subnet_self_link
  labels       = local.labels
}

resource "google_compute_address" "broker_external" {
  for_each     = local.brokers
  name         = "${var.name_prefix}-kafka-${each.key}-ext"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  labels       = local.labels
}

resource "google_compute_address" "driver_internal" {
  name         = "${var.name_prefix}-kafka-driver-int"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = var.subnet_self_link
  labels       = local.labels
}

resource "google_compute_address" "driver_external" {
  name         = "${var.name_prefix}-kafka-driver-ext"
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  labels       = local.labels
}

resource "google_compute_instance" "broker" {
  for_each     = local.brokers
  name         = "${var.name_prefix}-kafka-${each.key}"
  zone         = var.zone
  machine_type = var.broker_machine_type
  tags         = ["kafka-broker"]
  labels       = merge(local.labels, { role = "kafka-broker" })

  allow_stopping_for_update = false

  boot_disk {
    initialize_params {
      image = var.image
      size  = 50
      type  = "pd-balanced"
    }
  }

  # 375 GB local NVMe SSD; Kafka log.dirs lives here. Lost on stop/preemption.
  scratch_disk {
    interface = "NVME"
  }

  network_interface {
    subnetwork = var.subnet_self_link
    network_ip = google_compute_address.broker_internal[each.key].address

    access_config {
      nat_ip       = google_compute_address.broker_external[each.key].address
      network_tier = "PREMIUM"
    }
  }

  scheduling {
    provisioning_model          = var.use_spot ? "SPOT" : "STANDARD"
    preemptible                 = var.use_spot
    automatic_restart           = var.use_spot ? false : true
    on_host_maintenance         = var.use_spot ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.use_spot ? "DELETE" : null
  }

  metadata = merge(
    {
      user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
        role             = "broker"
        node_id          = each.key
        cluster_id       = local.cluster_id
        internal_ip      = google_compute_address.broker_internal[each.key].address
        external_ip      = google_compute_address.broker_external[each.key].address
        voters           = local.voters
        kafka_version    = var.kafka_version
        kafka_sha512     = var.kafka_sha512
        nvme_model_regex = var.nvme_model_regex
        mount_nvme       = "1"
        bootstrap_script = local.bootstrap_script
        configure_script = local.configure_script
      })
    },
    local.use_gcloud ? {} : { ssh-keys = "${var.ssh_user}:${local.ssh_pubkey}" }
  )

  # Re-applies must never replace a seeded broker.
  lifecycle {
    ignore_changes = [metadata, boot_disk[0].initialize_params[0].image]
  }
}

resource "google_compute_instance" "driver" {
  name         = local.driver_name
  zone         = var.zone
  machine_type = var.driver_machine_type
  tags         = ["kafka-driver"]
  labels       = merge(local.labels, { role = "kafka-driver" })

  allow_stopping_for_update = false

  boot_disk {
    initialize_params {
      image = var.image
      size  = 100
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnet_self_link
    network_ip = google_compute_address.driver_internal.address

    access_config {
      nat_ip       = google_compute_address.driver_external.address
      network_tier = "PREMIUM"
    }
  }

  scheduling {
    provisioning_model          = var.use_spot ? "SPOT" : "STANDARD"
    preemptible                 = var.use_spot
    automatic_restart           = var.use_spot ? false : true
    on_host_maintenance         = var.use_spot ? "TERMINATE" : "MIGRATE"
    instance_termination_action = var.use_spot ? "DELETE" : null
  }

  metadata = merge(
    {
      user-data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
        role             = "driver"
        node_id          = ""
        cluster_id       = local.cluster_id
        internal_ip      = google_compute_address.driver_internal.address
        external_ip      = google_compute_address.driver_external.address
        voters           = local.voters
        kafka_version    = var.kafka_version
        kafka_sha512     = var.kafka_sha512
        nvme_model_regex = var.nvme_model_regex
        mount_nvme       = "0"
        bootstrap_script = local.bootstrap_script
        configure_script = local.configure_script
      })
    },
    local.use_gcloud ? {} : { ssh-keys = "${var.ssh_user}:${local.ssh_pubkey}" }
  )

  lifecycle {
    ignore_changes = [metadata, boot_disk[0].initialize_params[0].image]
  }
}

# Firewall: rules replace, never append.
resource "google_compute_firewall" "internal" {
  name          = "${var.name_prefix}-kafka-internal"
  network       = var.network_self_link
  direction     = "INGRESS"
  source_ranges = [var.subnet_cidr]
  target_tags   = ["kafka-broker"]

  allow {
    protocol = "tcp"
    ports    = ["9092", "9093", "9094"]
  }
}

resource "google_compute_firewall" "pods" {
  name          = "${var.name_prefix}-kafka-pods"
  network       = var.network_self_link
  direction     = "INGRESS"
  source_ranges = [var.pod_cidr]
  target_tags   = ["kafka-broker"]

  allow {
    protocol = "tcp"
    ports    = ["9092", "9094"]
  }
}

resource "google_compute_firewall" "operator" {
  name          = "${var.name_prefix}-kafka-operator"
  network       = var.network_self_link
  direction     = "INGRESS"
  source_ranges = [var.operator_cidr]
  target_tags   = ["kafka-broker", "kafka-driver"]

  allow {
    protocol = "tcp"
    ports    = ["22", "9094"]
  }
}

# Readiness gate: wait until the KRaft quorum answers and 3 brokers are registered.
resource "null_resource" "kafka_ready" {
  triggers = {
    driver  = google_compute_instance.driver.instance_id
    brokers = join(",", [for b in google_compute_instance.broker : b.instance_id])
  }

  depends_on = [google_compute_firewall.operator]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    command     = "${path.module}/wait-for-kafka.sh"

    environment = {
      SSH_COMMAND     = local.driver_ssh_command
      USE_GCLOUD      = local.use_gcloud ? "1" : "0"
      BOOTSTRAP       = "${local.broker_internal_ips["1"]}:9092"
      TIMEOUT_SECONDS = tostring(var.readiness_timeout_seconds)
    }
  }
}
