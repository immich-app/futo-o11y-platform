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

output "egress_gateway" {
  value = cidrhost(local.netbird_egress_cidr, 1)
}
