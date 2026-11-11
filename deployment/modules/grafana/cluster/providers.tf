provider "grafana" {
  url  = local.grafana_url
  auth = "${var.grafana_admin_user}:${var.grafana_admin_password}"
}
