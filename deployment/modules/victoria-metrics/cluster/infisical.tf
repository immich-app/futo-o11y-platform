# The same items as onepassword.tf, in the shared project's /tf folder of this
# environment (the remote clusters read them next to the vmauth password),
# until 1Password is retired.
data "infisical_projects" "shared" {
  slug = "shared"
}

locals {
  # Mirrors the ENVIRONMENT_SHORT mapping in .mise/config.toml.
  env_short = var.env == "production" ? "prod" : var.env == "development" ? "dev" : var.env

  app_domain  = var.env == "production" ? "futostatus.com" : "${var.env}.futostatus.com"
  mesh_domain = var.env == "production" ? "o11y.futo.network" : "${var.env}.o11y.futo.network"

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
