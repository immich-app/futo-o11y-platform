variable "env" {}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

# The password the cluster's grafana-admin-password ExternalSecret also reads.
variable "grafana_admin_password" {
  type      = string
  sensitive = true
}
