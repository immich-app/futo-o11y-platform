# Talos ingress firewall: default-deny on host-bound services. Operators reach
# apid/apiserver through the NetBird route, masqueraded to a routing peer's
# vRack IP, so every allow rule is the vRack CIDR (+ pod CIDR for in-cluster
# clients). Exception: traffic addressed to the elected routing peer's OWN
# vRack IP is delivered locally and never traverses POSTROUTING, so masquerade
# does not fire and it arrives with the operator's NetBird peer source. apid
# (and the apiserver, see control-plane/) therefore also trust the NetBird peer
# CIDR (10.254.0.0/15). NetBird ACLs gate reachability and both services
# require client TLS regardless, except the apiserver's anonymous health
# endpoints.
#
# Pod-to-node-IP traffic on the same node skips the flannel masquerade and
# keeps its pod-IP source, so a rule that serves pods also allows the pod
# CIDR. Cross-node pod traffic arrives masqueraded to the vRack IP.
apiVersion: v1alpha1
kind: NetworkDefaultActionConfig
ingress: block
---
# Pod CIDR: tuppr's controller and upgrade Jobs talk to apid from pods.
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: apid
portSelector:
  ports:
    - 50000
  protocol: tcp
ingress:
  - subnet: {{ .Data.privateNetwork }}
  - subnet: 10.254.0.0/15
  - subnet: 10.244.0.0/16
---
# Pod CIDR: a pod scraping its own node's kubelet (e.g. metrics-server).
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: kubelet
portSelector:
  ports:
    - 10250
  protocol: tcp
ingress:
  - subnet: {{ .Data.privateNetwork }}
  - subnet: 10.244.0.0/16
---
# Flannel VXLAN overlay (backend port 4789). Pinned to the vRack via
# --iface-can-reach (control-plane/), so the only trusted source is the
# private CIDR.
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: flannel-vxlan
portSelector:
  ports:
    - 4789
  protocol: udp
ingress:
  - subnet: {{ .Data.privateNetwork }}
---
# Spegel peer-to-peer registry. containerd mirrors through the registry
# NodePort (30020, the chart default) on its own node IP. Intra-cluster only;
# the libp2p router (5001) and metrics ride the pod network.
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: spegel-registry
portSelector:
  ports:
    - 30020
  protocol: tcp
ingress:
  - subnet: {{ .Data.privateNetwork }}
---
# Node-level metrics: kube-proxy :10249 (bound to 0.0.0.0 by the cluster-wide
# KubeProxyConfig in control-plane/) and the node-exporter DaemonSet :9100.
# Both are plain HTTP without auth. Pod CIDR for the VMAgent self-scrape.
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: metrics-node
portSelector:
  ports:
    - 10249
    - 9100
  protocol: tcp
ingress:
  - subnet: {{ .Data.privateNetwork }}
  - subnet: 10.244.0.0/16
