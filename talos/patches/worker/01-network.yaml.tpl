# NIC names differ across OVH workers (even within a plan code), so each node
# names them in topf.yaml.
machine:
  network:
    interfaces:
      - interface: {{ .Node.Data.publicNic }}
        dhcp: true
      - interface: {{ .Node.Data.privateNic }}
        addresses:
          - {{ .Node.IP }}/{{ splitList "/" .Data.privateNetwork | last }}
