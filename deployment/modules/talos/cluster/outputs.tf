locals {
  secrets = talos_machine_secrets.this.machine_secrets
}

# The bundle in the secrets.yaml layout `talosctl gen secrets` writes, which
# topf's secrets provider (talos/bin/talos-secrets) hands over verbatim.
output "talos_secrets" {
  sensitive = true
  value = yamlencode({
    cluster = {
      id     = local.secrets.cluster.id
      secret = local.secrets.cluster.secret
    }
    secrets = merge(
      {
        bootstraptoken            = local.secrets.secrets.bootstrap_token
        secretboxencryptionsecret = local.secrets.secrets.secretbox_encryption_secret
      },
      local.secrets.secrets.aescbc_encryption_secret == null ? {} : {
        aescbcencryptionsecret = local.secrets.secrets.aescbc_encryption_secret
      },
    )
    trustdinfo = {
      token = local.secrets.trustdinfo.token
    }
    certs = {
      etcd = {
        crt = local.secrets.certs.etcd.cert
        key = local.secrets.certs.etcd.key
      }
      k8s = {
        crt = local.secrets.certs.k8s.cert
        key = local.secrets.certs.k8s.key
      }
      k8saggregator = {
        crt = local.secrets.certs.k8s_aggregator.cert
        key = local.secrets.certs.k8s_aggregator.key
      }
      k8sserviceaccount = {
        key = local.secrets.certs.k8s_serviceaccount.key
      }
      os = {
        crt = local.secrets.certs.os.cert
        key = local.secrets.certs.os.key
      }
    }
  })
}
