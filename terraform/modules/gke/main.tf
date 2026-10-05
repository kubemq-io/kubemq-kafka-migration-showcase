locals {
  labels   = merge({ showcase = "kafka-migration" }, var.labels)
  location = var.regional ? var.region : var.zone
  name     = "${var.name_prefix}-gke"
}

# Least-privilege node service account.
resource "google_service_account" "nodes" {
  account_id   = substr("${var.name_prefix}-gke-nodes", 0, 30)
  display_name = "GKE nodes (${var.name_prefix})"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
    "roles/artifactregistry.reader",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  name     = local.name
  location = local.location
  # Regional clusters still keep all nodes in one zone (no cross-zone traffic to Kafka).
  node_locations = var.regional ? [var.zone] : null

  network    = var.network_self_link
  subnetwork = var.subnet_self_link

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = var.operator_cidr
      display_name = "operator"
    }
  }

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  resource_labels = local.labels
}

resource "google_container_node_pool" "primary" {
  name       = "primary"
  cluster    = google_container_cluster.this.id
  node_count = var.node_count

  node_config {
    machine_type    = var.node_machine_type
    disk_size_gb    = var.node_disk_size_gb
    disk_type       = "pd-balanced"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = local.labels
    tags            = ["gke-node"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}
