terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Local state by default. For a shared backend, uncomment and fill in:
  # backend "gcs" {
  #   bucket = "my-tf-state-bucket"
  #   prefix = "kafka-migration-showcase/gcp/k8s-addons"
  # }
}
