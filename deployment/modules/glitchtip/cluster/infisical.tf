# The same items as onepassword.tf, in the observability project's /tf folder
# of this environment, until 1Password is retired.
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
