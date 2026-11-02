# Plaintext setup key fed to the Talos netbird extension (NB_SETUP_KEY); the
# talos/mise.toml tasks read it and topf resolves it into the machine configs.
output "talos_setup_key" {
  sensitive = true
  value     = netbird_setup_key.talos.key
}

# Routing-peer setup key; consumed by //bootstrap:resources -> netbird-setup-key Secret.
output "k8s_routing_peer_setup_key" {
  sensitive = true
  value     = netbird_setup_key.k8s_routing_peer.key
}

# CI runner setup key; the infra workflow reads it from state to join the mesh.
output "ci_setup_key" {
  sensitive = true
  value     = netbird_setup_key.ci.key
}

# Consumed by //bootstrap:resources -> bootstrap-settings ConfigMap (Flux substitution).
output "mesh_dns_zone" {
  value = local.mesh_dns_zone
}

output "gateway_vip" {
  value = local.netbird_gateway_vip
}

output "service_cidr" {
  value = local.netbird_service_cidr
}

output "egress_cidr" {
  value = local.netbird_egress_cidr
}
