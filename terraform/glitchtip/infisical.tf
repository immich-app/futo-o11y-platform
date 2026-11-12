# Publishes the S3 credentials to the observability project's /tf folder of
# this environment, for the cluster's glitchtip-s3 ExternalSecret.
data "infisical_projects" "observability" {
  slug = "observability"
}

locals {
  infisical_secrets = {
    GLITCHTIP_S3_ACCESS_KEY_ID     = ovh_cloud_project_user_s3_credential.glitchtip.access_key_id
    GLITCHTIP_S3_SECRET_ACCESS_KEY = ovh_cloud_project_user_s3_credential.glitchtip.secret_access_key
  }
}

resource "infisical_secret" "this" {
  for_each = toset(keys(local.infisical_secrets))

  workspace_id = data.infisical_projects.observability.id
  env_slug     = var.env_short
  folder_path  = "/tf"
  name         = each.key
  value        = local.infisical_secrets[each.key]

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}
