# The same items as onepassword.tf, in the observability project's /tf folder
# of this environment, until 1Password is retired.
data "infisical_projects" "observability" {
  slug = "observability"
}

resource "infisical_secret" "talos_setup_key" {
  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "NETBIRD_TALOS_SETUP_KEY"
  value        = netbird_setup_key.talos.key

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}

resource "infisical_secret" "k8s_routing_peer_setup_key" {
  workspace_id = data.infisical_projects.observability.id
  env_slug     = local.env_short
  folder_path  = "/tf"
  name         = "NETBIRD_K8S_ROUTING_PEER_SETUP_KEY"
  value        = netbird_setup_key.k8s_routing_peer.key

  metadata = {
    type   = "external"
    source = "terraform"
    repo   = "immich-app/futo-o11y-platform"
  }
}
