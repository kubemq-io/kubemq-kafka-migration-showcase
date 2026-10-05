provider "google" {
  project = var.project_id
}

# Provider configured from a data source, never from a resource in the same apply.
data "google_client_config" "current" {}

data "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.cluster_location
  project  = var.project_id
}

provider "kubernetes" {
  host                   = "https://${data.google_container_cluster.this.endpoint}"
  token                  = data.google_client_config.current.access_token
  cluster_ca_certificate = base64decode(data.google_container_cluster.this.master_auth[0].cluster_ca_certificate)
}
