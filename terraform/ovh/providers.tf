provider "ovh" {
  endpoint           = "ovh-eu"
  application_key    = var.ovh_application_key
  application_secret = var.ovh_application_secret
  consumer_key       = var.ovh_consumer_key
}

# Glance (images) has no OVH API, so the control-plane image goes through the
# OpenStack API with the user the project creates for it (ovh_cloud_project_user.image).
# Its password is known only after that user exists, so a new environment
# applies -target=ovh_cloud_project_user.image first (docs/01-bootstrap-guide.md).
provider "openstack" {
  auth_url         = ovh_cloud_project_user.image.openstack_rc["OS_AUTH_URL"]
  tenant_id        = ovh_cloud_project_user.image.openstack_rc["OS_TENANT_ID"]
  user_name        = ovh_cloud_project_user.image.username
  password         = ovh_cloud_project_user.image.password
  user_domain_name = "Default"
}
