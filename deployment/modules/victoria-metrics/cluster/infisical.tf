# The same items as onepassword.tf, in the shared project's /tf folder of this
# environment (the remote clusters read them next to the vmauth password),
# until 1Password is retired.
data "infisical_projects" "shared" {
  slug = "shared"
}

locals {
  infisical_secrets = {
    O11Y_VICTORIAMETRICS_VMAUTH_MESH_URL   = "https://vmauth.${local.mesh_domain}"
    O11Y_VICTORIAMETRICS_VMAUTH_PUBLIC_URL = "https://vmauth.${local.app_domain}"
  }
}

resource "infisical_secret" "this" {
  for_each = toset(keys(local.infisical_secrets))

  workspace_id = data.infisical_projects.shared.id
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
