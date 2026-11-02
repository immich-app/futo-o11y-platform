# The Talos secrets bundle (cluster, etcd and OS CAs, service-account key,
# tokens) lives only in this state. topf (talos/) reads it through the
# talos_secrets output to render every node's machine config.
resource "talos_machine_secrets" "this" {
  lifecycle {
    prevent_destroy = true
  }
}

# topf applies the machine configs and bootstraps etcd. Destroying a config
# apply resets its node (on_destroy reset = true), so these only leave state.
removed {
  from = talos_machine_configuration_apply.controlplane

  lifecycle {
    destroy = false
  }
}

removed {
  from = talos_machine_configuration_apply.worker

  lifecycle {
    destroy = false
  }
}

removed {
  from = talos_machine_bootstrap.this

  lifecycle {
    destroy = false
  }
}

removed {
  from = talos_cluster_kubeconfig.this

  lifecycle {
    destroy = false
  }
}
