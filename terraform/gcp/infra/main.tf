locals {
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "servicenetworking.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each           = toset(local.services)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "network" {
  source = "../../modules/network-gcp"

  name_prefix   = var.name_prefix
  region        = var.region
  primary_cidr  = var.subnet_cidr
  pods_cidr     = var.pods_cidr
  services_cidr = var.services_cidr

  depends_on = [google_project_service.this]
}

module "kafka" {
  source = "../../modules/kafka-gcp"

  name_prefix         = var.name_prefix
  project_id          = var.project_id
  region              = var.region
  zone                = var.zone
  network_self_link   = module.network.network_self_link
  subnet_self_link    = module.network.subnet_self_link
  subnet_cidr         = module.network.primary_cidr
  pod_cidr            = module.network.pods_cidr
  operator_cidr       = var.operator_cidr
  kafka_version       = var.kafka_version
  kafka_sha512        = var.kafka_sha512
  broker_machine_type = var.broker_machine_type
  driver_machine_type = var.broker_machine_type
  use_spot            = var.use_spot
  ssh_user            = var.ssh_user
  ssh_public_key_path = var.ssh_public_key_path

  depends_on = [google_project_service.this]
}

module "gke" {
  source = "../../modules/gke"

  name_prefix         = var.name_prefix
  project_id          = var.project_id
  region              = var.region
  zone                = var.zone
  regional            = var.gke_regional
  network_self_link   = module.network.network_self_link
  subnet_self_link    = module.network.subnet_self_link
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  operator_cidr       = var.operator_cidr
  node_machine_type   = var.node_machine_type

  depends_on = [google_project_service.this]
}
