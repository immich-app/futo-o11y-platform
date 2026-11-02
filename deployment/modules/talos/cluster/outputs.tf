# The bundle in the secrets.yaml layout `talosctl gen secrets` writes, which
# topf's secrets provider (talos/bin/talos-secrets) hands over verbatim.
output "talos_secrets" {
  sensitive = true
  value = yamlencode({
    cluster = {
      id     = talos_machine_secrets.this.machine_secrets.cluster.id
      secret = talos_machine_secrets.this.machine_secrets.cluster.secret
    }
    secrets = merge(
      {
        bootstraptoken            = talos_machine_secrets.this.machine_secrets.secrets.bootstrap_token
        secretboxencryptionsecret = talos_machine_secrets.this.machine_secrets.secrets.secretbox_encryption_secret
      },
      talos_machine_secrets.this.machine_secrets.secrets.aescbc_encryption_secret == null ? {} : {
        aescbcencryptionsecret = talos_machine_secrets.this.machine_secrets.secrets.aescbc_encryption_secret
      },
    )
    trustdinfo = {
      token = talos_machine_secrets.this.machine_secrets.trustdinfo.token
    }
    certs = {
      etcd = {
        crt = talos_machine_secrets.this.machine_secrets.certs.etcd.cert
        key = talos_machine_secrets.this.machine_secrets.certs.etcd.key
      }
      k8s = {
        crt = talos_machine_secrets.this.machine_secrets.certs.k8s.cert
        key = talos_machine_secrets.this.machine_secrets.certs.k8s.key
      }
      k8saggregator = {
        crt = talos_machine_secrets.this.machine_secrets.certs.k8s_aggregator.cert
        key = talos_machine_secrets.this.machine_secrets.certs.k8s_aggregator.key
      }
      k8sserviceaccount = {
        key = talos_machine_secrets.this.machine_secrets.certs.k8s_serviceaccount.key
      }
      os = {
        crt = talos_machine_secrets.this.machine_secrets.certs.os.cert
        key = talos_machine_secrets.this.machine_secrets.certs.os.key
      }
    }
  })
}
