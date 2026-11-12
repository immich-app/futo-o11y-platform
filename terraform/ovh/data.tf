data "ovh_me" "account" {
}

data "ovh_order_cart" "mycart" {
  ovh_subsidiary = data.ovh_me.account.ovh_subsidiary
}

data "ovh_cloud_project_flavors" "cp" {
  for_each = var.controlplane_nodes

  service_name = ovh_cloud_project.this.project_id
  region       = each.value.region
  name_filter  = each.value.flavor_name
}
