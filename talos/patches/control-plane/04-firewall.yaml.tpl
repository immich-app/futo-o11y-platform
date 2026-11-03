apiVersion: v1alpha1
kind: NetworkRuleConfig
name: trustd
portSelector:
  ports:
    - 50001
  protocol: tcp
ingress:
  - subnet: {{ .Data.privateNetwork }}
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: kube-apiserver
portSelector:
  ports:
    - 6443
  protocol: tcp
ingress:
  - subnet: {{ .Data.privateNetwork }}
  - subnet: 10.254.0.0/15
---
apiVersion: v1alpha1
kind: NetworkRuleConfig
name: etcd
portSelector:
  ports:
    - 2379-2380
  protocol: tcp
ingress:
  - subnet: {{ .Data.privateNetwork }}
---
# Control-plane component metrics, scraped by VMAgent on a worker
# (masqueraded to its vRack IP): controller-manager :10257 and scheduler
# :10259 (HTTPS, authenticated), etcd :2381 (HTTP without auth, so vRack/pod
# only is its only protection).
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
  - subnet: {{ .Data.privateNetwork }}
  - subnet: 10.244.0.0/16
