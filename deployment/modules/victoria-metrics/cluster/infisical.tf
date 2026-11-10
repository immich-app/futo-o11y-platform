# The same items as onepassword.tf, in the shared project's /tf folder of this
# environment (the remote clusters read them next to the vmauth password),
# until 1Password is retired.
data "infisical_projects" "shared" {
  slug = "shared"
}

resource "infisical_secret" "vmauth_mesh_url" {
  workspace_id = data.infisical_projects.shared.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "O11Y_VICTORIAMETRICS_VMAUTH_MESH_URL"
  value        = "https://vmauth.${local.mesh_domain}"

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}

resource "infisical_secret" "vmauth_public_url" {
  workspace_id = data.infisical_projects.shared.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "O11Y_VICTORIAMETRICS_VMAUTH_PUBLIC_URL"
  value        = "https://vmauth.${local.app_domain}"

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}
