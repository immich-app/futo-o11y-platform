# CoreDNS is installed by bootstrap/ and then managed by Flux: Flux needs DNS
# before it can install anything, and disabling Talos's copy keeps
# upgrade-k8s off the Corefile.
apiVersion: v1alpha1
kind: KubeCoreDNSConfig
enabled: false
---
# Metrics on all interfaces; see 01-network.yaml.tpl.
apiVersion: v1alpha1
kind: KubeControllerManagerConfig
extraArgs:
  bind-address: 0.0.0.0
---
# The default spread replaces the system defaults (hostname skew 3, zone skew
# 5), so pods without their own constraints still spread across the workers.
# ScheduleAnyway keeps them schedulable when a node is drained.
apiVersion: v1alpha1
kind: KubeSchedulerConfig
extraArgs:
  bind-address: 0.0.0.0
config:
  profiles:
    - schedulerName: default-scheduler
      pluginConfig:
        - name: PodTopologySpread
          args:
            defaultingType: List
            defaultConstraints:
              - maxSkew: 1
                topologyKey: kubernetes.io/hostname
                whenUnsatisfiable: ScheduleAnyway
---
# kube-proxy (nftables mode) defaults nodePortAddresses to the node's primary
# IP (the private vRack IP), so NodePorts only answered on the private NIC and
# the OVH IPLB (which hits the workers' PUBLIC IP) got dead probes. Open
# NodePorts on every interface so the public NIC serves 30443 too. The metrics
# address likewise defaults to localhost; bind :10249 to all interfaces for
# scraping (firewall-scoped). With this document kube-proxy reads a config
# file, so these are KubeProxyConfiguration fields, not flags (applies
# cluster-wide).
apiVersion: v1alpha1
kind: KubeProxyConfig
config:
  nodePortAddresses:
    - 0.0.0.0/0
  metricsBindAddress: 0.0.0.0:10249
---
# Flannel defaults its VXLAN endpoint to the default-route NIC (public), which
# sends east-west pod traffic over the internet and is dropped by the ingress
# firewall. Pin the VTEP to the vRack interface so VXLAN runs on the private
# network the firewall trusts.
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
extraArgs:
  - --iface-can-reach={{ .Data.privateGateway }}
---
# VIP for in-cluster traffic; CP private IPs for direct/break-glass operator
# access; kube.<mesh-zone> for the HA endpoint the mesh gateway fronts (Envoy
# TLS passthrough to the apiservers). The floating VIP does not ARP across
# DCs. The v1.14 defaults give kube-apiserver kubeadm-style
# startup/readiness/liveness probes, which need the generated
# KubeAuthenticationConfig's anonymous access to /livez, /readyz and /healthz;
# every other path still requires credentials.
apiVersion: v1alpha1
kind: KubeAPIServerConfig
certExtraSANs:
  - {{ (urlParse .ClusterEndpoint).hostname }}
{{- range .Data.controlplaneIps }}
  - {{ . }}
{{- end }}
  - kube.{{ .Data.meshDnsZone }}
