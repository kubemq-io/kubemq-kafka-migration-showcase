# AWS k8s-addons root: default gp3 StorageClass (EBS CSI driver installed by the
# infra root) plus the shared KubeMQ prerequisites (namespace, license Secret,
# management TLS Secret).

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = var.storage_class_name
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
    labels = { showcase = "kafka-migration" }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
    fsType    = "ext4"
  }
}

# EKS ships a gp2 StorageClass marked default. Two defaults make PVC binding
# depend on creation order, so drop the annotation from gp2.
resource "kubernetes_annotations" "gp2_not_default" {
  count = var.demote_gp2_default ? 1 : 0

  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  force       = true

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [kubernetes_storage_class_v1.gp3]
}

module "addons" {
  source = "../../modules/k8s-addons"

  namespace                    = var.kubemq_namespace
  release_name                 = var.kubemq_release_name
  license_key                  = var.kubemq_license_key
  existing_license_secret_name = var.kubemq_license_secret_name
}
