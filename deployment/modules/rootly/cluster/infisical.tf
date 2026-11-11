# The same items as onepassword.tf, in the observability project's /tf folder
# of this environment, until 1Password is retired.
data "infisical_projects" "observability" {
  slug = "observability"
}

locals {
  # Mirrors the ENVIRONMENT_SHORT mapping in .mise/config.toml.
  env_short = var.env == "production" ? "prod" : var.env == "development" ? "dev" : var.env

  infisical_secrets = merge(
    {
      ROOTLY_HEARTBEAT_PING_URL    = rootly_heartbeat.grafana_alerting.ping_url
      ROOTLY_HEARTBEAT_PING_SECRET = rootly_heartbeat.grafana_alerting.secret
    },
    length(rootly_heartbeat.remote_cluster) == 0 ? {} : {
      ROOTLY_HEARTBEAT_REMOTE_PING_URL    = rootly_heartbeat.remote_cluster[0].ping_url
      ROOTLY_HEARTBEAT_REMOTE_PING_SECRET = rootly_heartbeat.remote_cluster[0].secret
    },
    {
      for project in local.projects :
      "ROOTLY_ALERTS_${upper(project)}_URL" => "${local.grafana_webhooks_base}/notify/Service/${local.project_service_ids[project]}?secret=${rootly_alerts_source.grafana[project].secret}"
    },
  )
}

resource "infisical_secret" "this" {
  for_each = toset(keys(local.infisical_secrets))

  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = each.key
  value        = local.infisical_secrets[each.key]

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}
