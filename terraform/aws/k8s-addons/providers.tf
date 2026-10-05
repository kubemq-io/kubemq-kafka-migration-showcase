provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      showcase = "kafka-migration"
    }
  }
}

# The cluster is read from data sources, never from a resource in this root,
# so the Kubernetes provider is fully known before anything is planned.
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = var.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}
