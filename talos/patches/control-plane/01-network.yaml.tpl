machine:
  network:
    interfaces:
      # Static private IP rather than DHCP. OVH's private-network DHCP NAKs the
      # renew after a subnet/port rebuild ("address not available"), stranding
      # the CP off the vRack on reboot even though the port's fixed IP is
      # correct. The address matches that fixed IP, which port-security already
      # permits. The VIP layers on top.
      - interface: eth1
        addresses:
          - {{ .Node.IP }}/{{ splitList "/" .Data.privateNetwork | last }}
        vip:
          ip: {{ .Data.controlplaneVip }}
cluster:
  # Control-plane components bind their metrics to localhost by default, so
  # VMAgent (on a worker) cannot scrape them. Bind to all interfaces; the
  # ingress firewall keeps the ports private (vRack + pod CIDR only).
  # controller-manager (:10257) and scheduler (:10259) serve authenticated
  # HTTPS; etcd (:2381) is unauthenticated HTTP, so the firewall is its only
  # protection.
  etcd:
    # Peer and client URLs on the vRack only: the CPs also hold a public (eth0)
    # and a NetBird (wt0) address, and a reinstalled member must never
    # advertise those.
    advertisedSubnets:
      - {{ .Data.privateNetwork }}
    extraArgs:
      listen-metrics-urls: http://0.0.0.0:2381
