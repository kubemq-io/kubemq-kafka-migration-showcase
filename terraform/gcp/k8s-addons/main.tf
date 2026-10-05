module "addons" {
  source = "../../modules/k8s-addons"

  namespace                    = var.kubemq_namespace
  release_name                 = var.kubemq_release_name
  license_key                  = var.kubemq_license_key
  existing_license_secret_name = var.kubemq_license_secret_name
}
