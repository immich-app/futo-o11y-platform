terraform {
  required_version = "~> 1.10"

  required_providers {
    ovh = {
      source  = "ovh/ovh"
      version = "2.24.0"
    }
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "3.4.0"
    }
  }
}
