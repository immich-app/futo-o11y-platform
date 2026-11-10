# The same items as onepassword.tf, in the observability project's /tf folder
# of this environment, until 1Password is retired.
data "infisical_projects" "observability" {
  slug = "observability"
}

resource "infisical_secret" "heartbeat_ping_url" {
  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "ROOTLY_HEARTBEAT_PING_URL"
  value        = rootly_heartbeat.grafana_alerting.ping_url

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}

resource "infisical_secret" "heartbeat_ping_secret" {
  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "ROOTLY_HEARTBEAT_PING_SECRET"
  value        = rootly_heartbeat.grafana_alerting.secret

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}

resource "infisical_secret" "remote_heartbeat_ping_url" {
  count = length(rootly_heartbeat.remote_cluster)

  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "ROOTLY_HEARTBEAT_REMOTE_PING_URL"
  value        = rootly_heartbeat.remote_cluster[0].ping_url

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}

resource "infisical_secret" "remote_heartbeat_ping_secret" {
  count = length(rootly_heartbeat.remote_cluster)

  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "ROOTLY_HEARTBEAT_REMOTE_PING_SECRET"
  value        = rootly_heartbeat.remote_cluster[0].secret

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}

resource "infisical_secret" "grafana_alerts_url" {
  for_each = local.projects

  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "ROOTLY_ALERTS_${upper(each.key)}_URL"
  value        = "${local.grafana_webhooks_base}/notify/Service/${local.project_service_ids[each.key]}?secret=${rootly_alerts_source.grafana[each.key].secret}"

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}
