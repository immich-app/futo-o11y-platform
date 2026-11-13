# Infisical pushes this environment's /github folder to the repository's
# Actions secrets. The Terraform workflow joins the mesh with the CI setup key
# from there. In prod the folder also holds OPENROUTER_API_KEY, which an
# Infisical secret rotation writes for the Promote workflow
# (docs/01-bootstrap-guide.md).
resource "infisical_secret_folder" "github" {
  name             = "github"
  environment_slug = var.env_short
  folder_path      = "/"
  project_id       = data.infisical_projects.observability.id
}

resource "infisical_secret" "ci_setup_key" {
  workspace_id = data.infisical_projects.observability.id
  env_slug     = infisical_secret_folder.github.environment_slug
  folder_path  = infisical_secret_folder.github.path
  name         = "NETBIRD_O11Y_CI_SETUP_KEY_${upper(var.env_short)}"
  value        = netbird_setup_key.ci.key

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}

# The immich-app GitHub connection, made in the Infisical UI with the Infisical
# GitHub App: the provider can only create token-based GitHub connections.
locals {
  github_connection_immich_app = "5705b9f3-d44f-498b-88be-e8542dc008c8"
}

# One sync per environment, each with its own key names. Deletion stays off: a
# key that leaves the folder keeps its Actions secret, and the sync never touches
# the other environment's secrets or the repository's own. The CI plan
# identities can refresh the sync because core-infra-tf grants them read on
# secret syncs (secret_syncs in infisical/instance access.tf).
resource "infisical_secret_sync_github" "repository" {
  name              = "futo-o11y-platform-${var.env_short}"
  project_id        = data.infisical_projects.observability.id
  environment       = infisical_secret_folder.github.environment_slug
  secret_path       = infisical_secret_folder.github.path
  connection_id     = local.github_connection_immich_app
  auto_sync_enabled = true

  destination_config = {
    scope            = "repository"
    repository_owner = "immich-app"
    repository_name  = "futo-o11y-platform"
  }

  sync_options = {
    initial_sync_behavior   = "overwrite-destination"
    disable_secret_deletion = true
  }
}
