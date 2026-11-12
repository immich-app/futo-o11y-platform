resource "ovh_cloud_instance" "controlplane" {
  for_each = var.controlplane_nodes

  service_name = ovh_cloud_project.this.project_id
  region       = each.value.region
  name         = "o11y-${var.env}-cp-${each.key}"
  image_id     = openstack_images_image_v2.controlplane[each.value.region].id
  flavor_id = one([
    for f in data.ovh_cloud_instance_flavors.cp[each.key].flavors :
    f.id if f.name == each.value.flavor_name
  ])
  # Immutable: a different name replaces the instance (keys.tf).
  ssh_key_name = ovh_cloud_project_ssh_key.my_key.name

  # The private interface first: that is the order the import reads from the
  # API, and a reordered list is an in-place update of the interfaces.
  networks = [
    {
      network_id = ovh_cloud_network_private_vrack.cluster[each.value.region].id
      subnet_id  = ovh_cloud_network_private_vrack_subnet.cluster[each.key].id
      ip         = each.value.private_ip
    },
    { auto_assign_public_ip = true },
  ]

  lifecycle {
    # A changed image_id rebuilds the instance and wipes its root disk; Talos
    # upgrades go via machine.install.image, and the image only serves new nodes.
    ignore_changes  = [image_id]
    prevent_destroy = true
  }
}
