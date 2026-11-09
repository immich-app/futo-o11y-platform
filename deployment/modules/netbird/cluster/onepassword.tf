# The setup keys in the env vault, for the tools that consume them outside
# Terraform: topf (talos/<env>/topf.yaml) and //bootstrap:resources.
locals {
  # Mirrors the ENVIRONMENT_SHORT mapping in .mise/config.toml.
  env_short = var.env == "production" ? "prod" : var.env == "development" ? "dev" : var.env
}

data "onepassword_vault" "env" {
  name = "o11y_tf_${local.env_short}"
}

resource "onepassword_item" "talos_setup_key" {
  vault    = data.onepassword_vault.env.uuid
  title    = "NETBIRD_TALOS_SETUP_KEY"
  category = "password"
  password = netbird_setup_key.talos.key
}

resource "onepassword_item" "k8s_routing_peer_setup_key" {
  vault    = data.onepassword_vault.env.uuid
  title    = "NETBIRD_K8S_ROUTING_PEER_SETUP_KEY"
  category = "password"
  password = netbird_setup_key.k8s_routing_peer.key
}
