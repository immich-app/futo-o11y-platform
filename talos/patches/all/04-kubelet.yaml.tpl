# Pin the kubelet node IP to the vRack subnet, so the Kubernetes InternalIP is
# always the private IP. Otherwise the kubelet can pick a NetBird overlay
# address (when the private NIC has no IP yet at kubelet start) or the lowest
# 10.x host address (the Multus bridge IP once took a worker's InternalIP).
apiVersion: v1alpha1
kind: KubeNodeConfig
nodeIP:
  validSubnets:
    - {{ .Data.privateNetwork }}
---
# clusterDNS is explicit because Talos's CoreDNS is disabled; the Flux-managed
# chart (kubernetes/apps/base/coredns) keeps this Service IP. The shutdown
# grace periods (Talos default 30s/10s) give Postgres and vmstorage time to
# stop cleanly on an unplanned reboot; images unused for a week are
# garbage-collected (Spegel keeps unpacked layers).
apiVersion: v1alpha1
kind: KubeletConfig
clusterDNS:
  - 10.96.0.10
config:
  shutdownGracePeriod: 90s
  shutdownGracePeriodCriticalPods: 60s
  imageMaximumGCAge: 168h
