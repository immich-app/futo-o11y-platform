# The Talos secrets bundle (cluster, etcd and OS CAs, service-account key,
# tokens) lives only in this state. topf (talos/) reads it through the
# talos_secrets output to render every node's machine config.
resource "talos_machine_secrets" "this" {
  lifecycle {
    prevent_destroy = true
  }
}
