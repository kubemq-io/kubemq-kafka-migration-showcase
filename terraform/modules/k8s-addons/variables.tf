variable "namespace" {
  description = "Namespace KubeMQ is installed into."
  type        = string
  default     = "kubemq"
}

variable "release_name" {
  description = "KubeMQ installation name (kmq deploy --name); drives Service and pod DNS names."
  type        = string
  default     = "kubemq"
}

variable "server_count" {
  description = "Number of KubeMQ servers; one TLS SAN per pod."
  type        = number
  default     = 3
}

variable "license_key" {
  description = "KubeMQ license key. Set this OR existing_license_secret_name, or leave both null and pass a saved kmq license credential (kmq license list) in the deploy input instead."
  type        = string
  default     = null
  sensitive   = true
}

variable "existing_license_secret_name" {
  description = "Name of a pre-created Secret in the namespace holding the license under key \"licenseKey\". Set this OR license_key."
  type        = string
  default     = null
}

variable "license_secret_name" {
  description = "Name of the license Secret created when license_key is set."
  type        = string
  default     = "kubemq-license"
}

variable "tls_secret_name" {
  description = "Name of the management TLS Secret. Empty means <release_name>-management-tls."
  type        = string
  default     = ""
}

variable "tls_validity_hours" {
  description = "Validity of the self-signed management certificate."
  type        = number
  default     = 8760
}

variable "labels" {
  description = "Extra labels merged into every created object."
  type        = map(string)
  default     = {}
}
