# Publishes the setup keys to the observability project's /tf folder of this
# environment, for the tools that use them outside Terraform: topf
# (//talos tasks), //bootstrap:resources and external-dns.
data "infisical_projects" "observability" {
  slug = "observability"
}

locals {
  # Mirrors the ENVIRONMENT_SHORT mapping in .mise/config.toml.
  env_short = var.env == "production" ? "prod" : var.env == "development" ? "dev" : var.env

  infisical_secrets = {
    NETBIRD_TALOS_SETUP_KEY            = netbird_setup_key.talos.key
    NETBIRD_K8S_ROUTING_PEER_SETUP_KEY = netbird_setup_key.k8s_routing_peer.key
    NETBIRD_EXTERNAL_DNS_API_TOKEN     = netbird_token.external_dns.token
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
