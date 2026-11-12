# Native (untagged) vRack VLAN, so vlan_id = 0. Env isolation comes from separate
# vRacks, not VLAN tags. The network is regional: one resource per
# control-plane region, all on the same VLAN.
resource "ovh_cloud_network_private_vrack" "cluster" {
  for_each = toset([for n in var.controlplane_nodes : n.region])

  service_name = ovh_cloud_project.this.project_id
  region       = each.key
  name         = "o11y-${var.env}"
  vlan_id      = 0

  depends_on = [ovh_vrack_cloudproject.this]
}

resource "ovh_cloud_network_private_vrack_subnet" "cluster" {
  for_each = var.controlplane_nodes

  service_name = ovh_cloud_project.this.project_id
  network_id   = ovh_cloud_network_private_vrack.cluster[each.value.region].id
  region       = each.value.region
  name         = "o11y-${var.env}-${each.key}"
  cidr         = var.private_network_cidr
  dhcp_enabled = true

  # No subnet gateway IP: with one, OVH makes the private gateway the instance
  # default route, which strands the CP's egress off its public NIC. The v2
  # resource has no switch for it; the provider leaves the gateway out of the
  # request when gateway_ip is unset, and the postcondition stops an apply
  # before any instance if the API assigned one anyway.
  dns_nameservers = ["1.1.1.1", "9.9.9.9"]

  lifecycle {
    postcondition {
      condition     = self.gateway_ip == null
      error_message = "The subnet ${self.name} got a gateway IP; the control planes must not get a private default route."
    }
  }
}
