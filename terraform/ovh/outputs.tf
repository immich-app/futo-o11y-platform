output "controlplane_nodes" {
  value = {
    for k, v in ovh_cloud_project_instance.controlplane : k => {
      name       = v.name
      region     = var.controlplane_nodes[k].region
      public_ip  = one([for a in v.addresses : a.ip if a.version == 4 && a.ip != var.controlplane_nodes[k].private_ip])
      private_ip = var.controlplane_nodes[k].private_ip
    }
  }
}

output "worker_nodes" {
  value = {
    for k, v in ovh_dedicated_server.worker : k => {
      name       = v.display_name
      datacenter = var.worker_nodes[k].datacenter
      public_ip  = v.ip
      private_ip = var.worker_nodes[k].private_ip
    }
  }
}

output "private_network_cidr" {
  value = var.private_network_cidr
}

# Consumed by `mise run //bootstrap:image`, so the CP image facts (schematic,
# version, glance name, regions) live only in this module. Sensitive: openstack
# holds the password of the upload user.
output "cp_image" {
  sensitive = true
  value = {
    download_url = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/openstack-amd64.raw.xz"
    glance_name  = local.cp_image_name
    regions      = distinct([for n in var.controlplane_nodes : n.region])
    openstack = {
      auth_url   = ovh_cloud_project_user.image.openstack_rc["OS_AUTH_URL"]
      project_id = ovh_cloud_project_user.image.openstack_rc["OS_TENANT_ID"]
      username   = ovh_cloud_project_user.image.username
      password   = ovh_cloud_project_user.image.password
    }
  }
}
