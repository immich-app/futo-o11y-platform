output "controlplane_nodes" {
  value = {
    for k, v in ovh_cloud_instance.controlplane : k => {
      name       = v.name
      region     = var.controlplane_nodes[k].region
      public_ip  = one([for a in flatten([for n in v.current_state.networks : n.addresses]) : a.ip if a.version == 4 && a.ip != var.controlplane_nodes[k].private_ip])
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
