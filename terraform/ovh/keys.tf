# Still the deprecated v1 resource: the v2 API (ovh_cloud_ssh_key) does not
# see this key, so it cannot be imported, and ssh_key_name is immutable on the
# control planes, which were created with it. Talos ignores the key. Replace
# it with an ovh_cloud_ssh_key when the control planes are next rebuilt.
resource "ovh_cloud_project_ssh_key" "my_key" {
  service_name = ovh_cloud_project.this.project_id

  name       = "my_key"
  public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG3/TlFlL/byLbM5aCt5QptpYSQCJIYFxKtjEtkAD5KI my-key"
}


