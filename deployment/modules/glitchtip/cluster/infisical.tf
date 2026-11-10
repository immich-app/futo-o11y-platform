# The same items as onepassword.tf, in the observability project's /tf folder
# of this environment, until 1Password is retired.
data "infisical_projects" "observability" {
  slug = "observability"
}

resource "infisical_secret" "glitchtip_s3_access_key_id" {
  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "GLITCHTIP_S3_ACCESS_KEY_ID"
  value        = ovh_cloud_project_user_s3_credential.glitchtip.access_key_id

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}

resource "infisical_secret" "glitchtip_s3_secret_access_key" {
  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "GLITCHTIP_S3_SECRET_ACCESS_KEY"
  value        = ovh_cloud_project_user_s3_credential.glitchtip.secret_access_key

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}
