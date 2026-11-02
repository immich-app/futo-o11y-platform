data "talos_machine_configuration" "controlplane" {
  cluster_name       = local.cluster_name
  cluster_endpoint   = local.cluster_endpoint
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version != "" ? var.kubernetes_version : null
  # The config contract (schema and defaults), independent of the installed Talos
  # version. Unset, it tracks the provider's bundled SDK, so a provider bump
  # regenerates every node's config. Never set it above the nodes' Talos minor.
  # From v1.14 the Kubernetes, install and CRI settings live in their own
  # documents; Talos rejects a config that also sets the old v1alpha1 field.
  talos_version = "v1.14"
}

resource "talos_machine_configuration_apply" "controlplane" {
  for_each = var.controlplane_nodes

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = local.controlplane_endpoint_ips[each.key]
  apply_mode                  = var.apply_mode

  on_destroy = {
    reboot   = true
    reset    = true
    graceful = false
  }

  config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [
            {
              # Static private IP rather than DHCP. OVH's private-network DHCP
              # NAKs the renew after a subnet/port rebuild ("address not
              # available"), stranding the CP off the vRack on reboot even though
              # the port's fixed IP is correct. The address matches that fixed IP,
              # which port-security already permits. The VIP layers on top.
              interface = "eth1"
              addresses = ["${each.value.private_ip}/${split("/", var.private_network_cidr)[1]}"]
              vip = {
                ip = local.controlplane_vip
              }
            }
          ]
        }
      }
      cluster = {
        # Control-plane components bind their metrics to localhost by default, so
        # VMAgent (on a worker) can't scrape them. Bind to all interfaces; the
        # Talos ingress firewall below keeps the ports private (vRack + pod CIDR
        # only) — the public NIC stays default-deny. controller-manager (:10257)
        # and scheduler (:10259) serve authenticated HTTPS; etcd (:2381) is
        # unauthenticated HTTP, so the firewall is its only protection.
        etcd = {
          extraArgs = {
            "listen-metrics-urls" = "http://0.0.0.0:2381"
          }
        }
      }
    }),
    # Only read for a fresh install: an installed node records the install as done
    # and never re-runs the installer.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "UnattendedInstallConfig"
      installer = {
        image = var.talos_installer_images.public_cloud
      }
      provisioning = {
        diskSelector = {
          match = "disk.dev_path == \"${var.controlplane_disk}\""
        }
      }
    }),
    # Spegel (kube-system DaemonSet) serves images peer-to-peer, so containerd
    # must keep unpacked layers around to serve them. Changing this restarts
    # containerd without a reboot.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "CRICustomizationConfig"
      name       = "spegel"
      content    = <<-TOML
        [plugins."io.containerd.cri.v1.images"]
          discard_unpacked_layers = false
      TOML
    }),
    # Pin the kubelet's node IP to the vRack subnet so the Kubernetes
    # InternalIP is always the private IP and never falls back to a mesh
    # overlay address (which happens if eth1 has no IP at kubelet
    # start — see the static address above).
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeNodeConfig"
      nodeIP = {
        validSubnets = [var.private_network_cidr]
      }
    }),
    # Explicit: Talos CoreDNS is disabled; the TF-seeded chart keeps this Service IP.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeletConfig"
      clusterDNS = ["10.96.0.10"]
    }),
    # CoreDNS is TF-seeded (kubernetes/helm): Flux needs DNS before it can install
    # anything, and disabling Talos's copy keeps upgrade-k8s off the Corefile.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeCoreDNSConfig"
      enabled    = false
    }),
    # Metrics on all interfaces; see the etcd note above.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeControllerManagerConfig"
      extraArgs = {
        "bind-address" = "0.0.0.0"
      }
    }),
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeSchedulerConfig"
      extraArgs = {
        "bind-address" = "0.0.0.0"
      }
    }),
    # kube-proxy (nftables mode) defaults nodePortAddresses to the node's
    # primary IP — here the private vRack IP — so NodePorts only answered on
    # the private NIC and the OVH IPLB (which hits the workers' PUBLIC IP)
    # got dead probes. Open NodePorts on every interface so the public NIC
    # serves 30443 too. The metrics address likewise defaults to localhost;
    # bind :10249 to all interfaces for scraping (firewall-scoped below).
    # With this document kube-proxy reads a config file, so these are
    # KubeProxyConfiguration fields, not flags (applies cluster-wide).
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeProxyConfig"
      config = {
        nodePortAddresses  = ["0.0.0.0/0"]
        metricsBindAddress = "0.0.0.0:10249"
      }
    }),
    # Flannel defaults its VXLAN endpoint to the default-route NIC (public),
    # which sends east-west pod traffic over the internet and is dropped by
    # the ingress firewall. Pin the VTEP to the vRack interface so VXLAN runs
    # on the private network the firewall trusts.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeFlannelCNIConfig"
      extraArgs  = ["--iface-can-reach=${cidrhost(var.private_network_cidr, 1)}"]
    }),
    # VIP for in-cluster traffic; CP private IPs for direct/break-glass operator
    # access; kube.<mesh-zone> for the HA endpoint the mesh gateway fronts (Envoy
    # TLS-passthrough -> apiservers). The floating VIP doesn't ARP across DCs.
    # The v1.14 defaults give kube-apiserver kubeadm-style startup/readiness/liveness
    # probes, which need the generated KubeAuthenticationConfig's anonymous access
    # to /livez, /readyz and /healthz; every other path still requires credentials.
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "KubeAPIServerConfig"
      certExtraSANs = concat(
        [local.controlplane_vip],
        [for k in local.controlplane_keys : var.controlplane_nodes[k].private_ip],
        ["kube.${var.mesh_dns_zone}"],
      )
    }),
    # The v1.14 contract enables workload isolation (sandboxd) by default. Turning
    # it on restarts containerd, the kubelet and every pod, so it is not part of
    # the contract change. The generated FilesystemTrimConfig (weekly trim of
    # every eligible volume) is kept.
    yamlencode({
      apiVersion        = "v1alpha1"
      kind              = "SecurityProfileConfig"
      workloadIsolation = false
    }),
    # `auto: "off"` must be quoted — YAML 1.1 parses bare `off` as the boolean
    # false, but the AutoHostnameKind enum needs the literal string.
    <<-EOT
      apiVersion: v1alpha1
      kind: HostnameConfig
      auto: "off"
      hostname: ${each.value.name}
    EOT
    ,
    # Netbird overlay — the node management mesh. Operators reach the vRack IPs
    # via the Netbird route (server-side, masqueraded to a routing-peer's vRack
    # IP). NB_MANAGEMENT_URL is set explicitly to mirror yucca (Cloud default).
    <<-EOT
      name: netbird
      apiVersion: v1alpha1
      kind: ExtensionServiceConfig
      environment:
      - NB_SETUP_KEY=${var.netbird_setup_key}
      - NB_MANAGEMENT_URL=https://api.netbird.io
    EOT
    ,
    # Talos ingress firewall — default-deny on host-bound services. Operators reach
    # apid/apiserver via the Netbird route, masqueraded to a routing-peer's vRack IP,
    # so every allow rule is the vRack CIDR (+ pod CIDR for in-cluster metrics).
    # Exception: traffic addressed to the elected routing peer's OWN vRack IP is
    # delivered locally and never traverses POSTROUTING, so masquerade doesn't fire
    # and it arrives with the operator's Netbird peer source. apid/apiserver
    # therefore also trust the Netbird peer CIDR (10.254.0.0/15) — Netbird ACLs
    # gate reachability and both services require client TLS regardless, except
    # the apiserver's anonymous health endpoints (see KubeAPIServerConfig above).
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkDefaultActionConfig
      ingress: block
    EOT
    ,
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: apid
      portSelector:
        ports:
          - 50000
        protocol: tcp
      ingress:
        - subnet: ${var.private_network_cidr}
        - subnet: 10.254.0.0/15
    EOT
    ,
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: trustd
      portSelector:
        ports:
          - 50001
        protocol: tcp
      ingress:
        - subnet: ${var.private_network_cidr}
    EOT
    ,
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: kube-apiserver
      portSelector:
        ports:
          - 6443
        protocol: tcp
      ingress:
        - subnet: ${var.private_network_cidr}
        - subnet: 10.254.0.0/15
    EOT
    ,
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: etcd
      portSelector:
        ports:
          - 2379-2380
        protocol: tcp
      ingress:
        - subnet: ${var.private_network_cidr}
    EOT
    ,
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: kubelet
      portSelector:
        ports:
          - 10250
        protocol: tcp
      # Pod CIDR is allowed too: pod-to-node-IP on the same node skips the
      # flannel masquerade, so a pod scraping its own kubelet (e.g. metrics-server
      # colocated with the node it's scraping) keeps its pod-IP source and would
      # otherwise be dropped. Cross-node pod→kubelet still works via masquerade
      # but adding 10.244.0.0/16 makes self-hits work without depending on it.
      ingress:
        - subnet: ${var.private_network_cidr}
        - subnet: 10.244.0.0/16
    EOT
    ,
    # Flannel VXLAN overlay (kube-flannel runs with backend port 4789). Pinned to
    # the vRack via --iface-can-reach above, so the only trusted source is the
    # private CIDR.
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: flannel-vxlan
      portSelector:
        ports:
          - 4789
        protocol: udp
      ingress:
        - subnet: ${var.private_network_cidr}
    EOT
    ,
    # Spegel peer-to-peer registry. containerd mirrors through the registry
    # NodePort (30020, the chart default) on its own node IP. Intra-cluster
    # only — the libp2p router (5001) and metrics ride the pod network.
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: spegel-registry
      portSelector:
        ports:
          - 30020
        protocol: tcp
      ingress:
        - subnet: ${var.private_network_cidr}
    EOT
    ,
    # Control-plane component metrics (scraped by VMAgent on a worker, masqueraded
    # to its vRack IP). controller-manager :10257 + scheduler :10259 (HTTPS, authed),
    # etcd :2381 (HTTP, unauthed — vRack/pod-only is its only protection).
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: metrics-controlplane
      portSelector:
        ports:
          - 10257
          - 10259
          - 2381
        protocol: tcp
      ingress:
        - subnet: ${var.private_network_cidr}
        - subnet: 10.244.0.0/16
    EOT
    ,
    # Node-level metrics that also run on CPs: kube-proxy :10249 and the
    # node-exporter DaemonSet :9100 (both HTTP, unauthed). Pod CIDR is included
    # for the VMAgent self-hit case (same-node scrape skips flannel masquerade).
    <<-EOT
      apiVersion: v1alpha1
      kind: NetworkRuleConfig
      name: metrics-node
      portSelector:
        ports:
          - 10249
          - 9100
        protocol: tcp
      ingress:
        - subnet: ${var.private_network_cidr}
        - subnet: 10.244.0.0/16
    EOT
  ]
}
