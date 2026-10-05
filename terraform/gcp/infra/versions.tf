terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  # Local state by default. For a shared backend, uncomment and fill in:
  # backend "gcs" {
  #   bucket = "my-tf-state-bucket"
  #   prefix = "kafka-migration-showcase/gcp/infra"
  # }
}
