data "ovh_order_cart_product_plan" "cloud_project" {
  cart_id        = data.ovh_order_cart.mycart.id
  price_capacity = "renew"
  product        = "cloud"
  plan_code      = "project.2018"
}

resource "ovh_cloud_project" "this" {
  ovh_subsidiary = data.ovh_me.account.ovh_subsidiary
  description    = "o11y-${var.env}"

  plan {
    duration     = data.ovh_order_cart_product_plan.cloud_project.selected_price.0.duration
    plan_code    = data.ovh_order_cart_product_plan.cloud_project.plan_code
    pricing_mode = data.ovh_order_cart_product_plan.cloud_project.selected_price.0.pricing_mode
  }
}

# The OpenStack user that the openstack provider uploads the control-plane
# image with (images.tf). OVH returns the password only when it creates the
# user, so the state holds the only copy.
resource "ovh_cloud_project_user" "image" {
  service_name = ovh_cloud_project.this.project_id
  description  = "o11y-${var.env} image upload"
  role_name    = "image_operator"
}
