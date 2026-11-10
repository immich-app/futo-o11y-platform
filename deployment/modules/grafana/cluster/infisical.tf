# The same items as onepassword.tf, in the observability project's /tf folder
# of this environment, until 1Password is retired.
data "infisical_projects" "observability" {
  slug = "observability"
}

resource "infisical_secret" "rootly_service_account_token" {
  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "ROOTLY_GRAFANA_SERVICE_ACCOUNT_TOKEN"
  value        = grafana_service_account_token.rootly.key

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}
