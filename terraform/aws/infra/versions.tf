terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

  # State is local by default. To share state, uncomment and fill in a bucket
  # you own, then run `terraform init -migrate-state`.
  # backend "s3" {
  #   bucket         = "my-tfstate-bucket"
  #   key            = "kmq-showcase/aws/infra.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "my-tfstate-locks"
  #   encrypt        = true
  # }
}
