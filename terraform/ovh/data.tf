data "ovh_me" "account" {
}

data "ovh_order_cart" "mycart" {
  ovh_subsidiary = data.ovh_me.account.ovh_subsidiary
}

# Image must be pre-uploaded via `mise run //bootstrap:image` before apply; the OVH
# provider doesn't upload custom images. The name comes from the version and the
# schematic, so a new image never reuses the name of an older one.
locals {
  cp_image_name = "talos-${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}"
}

data "ovh_cloud_project_images" "talos" {
  for_each = var.controlplane_nodes

  service_name = ovh_cloud_project.this.project_id
  region       = each.value.region
  os_type      = "linux"
}

data "ovh_cloud_project_flavors" "cp" {
  for_each = var.controlplane_nodes

  service_name = ovh_cloud_project.this.project_id
  region       = each.value.region
  name_filter  = each.value.flavor_name
}
