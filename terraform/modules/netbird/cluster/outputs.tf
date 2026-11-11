# CI runner setup key; the infra workflow reads it from state to join the mesh.
output "ci_setup_key" {
  sensitive = true
  value     = netbird_setup_key.ci.key
}

# The bootstrap-settings ConfigMap that //bootstrap:resources applies; Flux
# substitutes its values into the manifests (kubernetes/clusters/<env>/apps.yaml).
# An apply does not update the cluster: run //bootstrap:resources after a change.
output "bootstrap_settings" {
  value = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "bootstrap-settings"
      namespace = "flux-system"
    }
    data = {
      BOOTSTRAP_MESH_DOMAIN          = local.mesh_dns_zone
      BOOTSTRAP_NETBIRD_GATEWAY_VIP  = local.netbird_gateway_vip
      BOOTSTRAP_NETBIRD_SERVICE_CIDR = local.netbird_service_cidr
      BOOTSTRAP_NETBIRD_EGRESS_CIDR  = local.netbird_egress_cidr
      BOOTSTRAP_NETBIRD_EGRESS_GW    = cidrhost(local.netbird_egress_cidr, 1)
    }
  })
}

# Registered in IPAM by netbox/cluster.
output "service_cidr" {
  value = local.netbird_service_cidr
}

output "egress_cidr" {
  value = local.netbird_egress_cidr
}
