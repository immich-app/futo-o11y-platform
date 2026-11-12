# Infrastructure architecture guide

This guide describes the OVH foundation under the cluster: compute, private network and public ingress. Each environment is a fully independent build of the same shape. The environments differ only in the worker tier and the number of IPLB zones.

> Status: both environments, `o11y-staging` and `o11y-production`, are built and running. They have the same shape. Production has larger workers and multi-zone ingress.

## Shape

Each environment has one cluster with 3 control planes and 3 workers. The cluster spans multiple data centers (DCs):

- Control planes run on OVH Public Cloud in RBX-A, GRA9 and EU-WEST-PAR. These are the three DCs with the lowest round-trip time (RTT). The worst pair is at about 5 ms, well inside the latency tolerance of etcd. etcd keeps quorum with 2 of 3. So if one DC fails, the API stays up.
- Workers run on bare metal in RBX, GRA and SBG. Workers do not take part in etcd consensus, so the higher RTT to SBG is acceptable. If a node or a DC fails, the pods reschedule to the remaining DCs.

Storage is local to each node (OpenEBS hostpath). No block storage replicates across DCs. This is by design, because VictoriaMetrics replicates at the application layer. No replication runs between the environments. Each environment stands alone on its own vRack.

## Hardware

The staging specs match the live cluster.

| Role                | Plan                                 | Spec                                                                                               | DCs                      |
| ------------------- | ------------------------------------ | -------------------------------------------------------------------------------------------------- | ------------------------ |
| Control plane       | `b3-8` (Public Cloud)                | 2 vCPU, 8 GB RAM, 50 GB NVMe, 4 Gbps private                                                       | RBX-A, GRA9, EU-WEST-PAR |
| Worker (staging)    | `SYS-2` (`24sys022`, bare metal)     | Intel Xeon D-2141I, 8c/16t, 32 GB ECC DDR4, 2× 512 GB NVMe (WDC CL SN720), 1 Gbps public + private | RBX, GRA, SBG            |
| Worker (production) | `Rise-2` (`24rise02-v1`, bare metal) | Intel Xeon-E 2388G, 8c/16t, 128 GB ECC DDR4, 3× 1.92 TB NVMe, 1 Gbps public + 2 Gbps vRack         | RBX, GRA, SBG            |

Both environments use the same control-plane tier. The production workers add RAM and a third NVMe to carry more observability storage.

## vRack (private L2)

All east-west traffic (traffic between the nodes) inside the cluster goes over the OVH vRack. The vRack is an L2 network that spans every DC. This traffic includes etcd, apiserver, kubelet, flannel VXLAN and Spegel peering. The Public Cloud private networks and the bare-metal vRack interfaces share one untagged VLAN. So the control planes and the workers see each other as one L2 segment. The vRack is also the trust boundary for the Talos host firewall.

Each environment has its own vRack and its own private CIDR. Staging uses `10.150.200.0/24`, and production uses `10.150.100.0/24`. So a misconfigured deploy in one environment cannot reach another environment over the private network. Every node has a static private IP on its vRack interface. The control-plane API is at a Talos floating VIP (virtual IP), the `.5` address in the CIDR of the environment (`10.150.200.5` in staging).

## Public ingress: IP Load Balancing (IPLB)

Each environment has one managed OVH IP Load Balancing instance (`lb1` tier) for public ingress. The load balancer (LB) accepts backends by IP, so the bare-metal workers attach to it directly. Each LB zone has a TCP `:443` front-end and a farm (the OVH name for a backend pool). The farm forwards to the public Envoy NodePort (`30443`) of the workers. It uses PROXY protocol v2, so Envoy sees the real client IP. TLS terminates at Envoy.

The host firewall on the workers accepts `:30443` only from the IPLB NAT range of OVH (`10.108.0.0/14`). These are RFC1918 addresses inside the OVH network. So the public internet cannot reach the port directly. It also cannot spoof such a source address past the OVH edge. The LB is the only ingress path. Terraform points the name of the environment (`staging.futostatus.com`, or `futostatus.com` in production) at the public IP of the IPLB. external-dns adds one CNAME for each route host on the public gateway, which points at that name.

- Staging: one zone (`gra`). If that LB zone fails, staging ingress goes down. This is acceptable.
- Production: multi-zone anycast across `gra`, `rbx` and `sbg`. Each zone announces the same public IP. So if one OVH zone fails, ingress stays up.

Because the farm targets the public IPs of the workers and not the vRack, the cluster configuration handles three requirements:

- NodePorts must answer on the public NIC.
- Exactly one Envoy must run on each worker.
- Envoy must parse PROXY protocol.

See the cluster architecture guide for these details.

## NetBird mesh

NetBird connects operators, other FUTO clusters and the bootstrap cluster to this environment, and it exposes nothing publicly. Terraform manages all of it (`netbird/cluster`, objects named `o11y-<env>-*`). Each environment has its own groups, networks and policies, so access to staging cannot pivot into production. The mesh has four building blocks:

- Node mesh (operator access): NetBird runs as a Talos system extension on every node. NetBird advertises the vRack subnet as a network route, with the Talos nodes as routing peers. Any node can route, so the route is HA (highly available). Operator traffic to the other nodes arrives masqueraded: its source address is the vRack IP of the routing peer. The elected router delivers traffic for its own IP locally, without masquerade. So the host firewall also trusts the NetBird peer range on the management ports. Two policies give the shared `yucca` operator group the management ports only (apid `50000`, kube-apiserver `6443`):
  - `yucca → resource` covers the routed subnet.
  - `yucca → talos` covers the nodes as peers. This policy keeps the elected router reachable at its own IP. It also makes every node reachable at its NetBird peer IP. This works even with the cluster down.

  `talosctl` uses this path.

- Workload ingress (mesh gateway): `netbird-router` pods in the cluster are the routing peers for a pinned Envoy gateway VIP. The VIP is a ClusterIP from a dedicated secondary ServiceCIDR, and NetBird advertises it as a `/32` resource. The DNAT of kube-proxy runs in the network namespace (netns) of the host. So only routing at pod level can advertise a ClusterIP, and that is why these pods exist. For mesh peers, external-dns keeps one A record in the NetBird DNS zone `<mesh-domain>` for each route host on the mesh gateway, and each record points at the VIP. The `yucca` group can reach `:443` (mesh-facing HTTPRoutes) and `:6443`. The second port serves the HA kube-apiserver endpoint `kube.<mesh-domain>`, which `kubectl` uses by default. This endpoint load-balances across every apiserver and never loops through a routing peer.
- Pod egress (Multus): Normally, pods cannot originate mesh traffic. NetBird masquerades only traffic from ranges that a peer advertises, and the flannel pod CIDR is not one of them. A pod that needs the mesh opts in through a Multus `NetworkAttachmentDefinition`. The pod then gets a second interface in an egress range that the nodes advertise. The route on that interface covers only the service CIDR of the bootstrap cluster, which holds the VIPs of Infisical and opc. The NetBird client of the node carries that traffic out. All other traffic stays on flannel. Today, only gatus uses this path: it probes `opc.<project>.futo.network/heartbeat` of the other projects. The external-secrets controller still has the interface, but sends no traffic through it.
- External Secrets peer: the external-secrets controller runs nblink, a NetBird peer in userspace, as a sidecar. The peer has its own group and ephemeral setup key, and one policy lets it reach `infisical.futo.network` on tcp/443. The controller connects to the sidecar on `127.0.0.1:18080`.
- Mesh DNS: the router pods also serve NetBird DNS to the cluster. CoreDNS forwards the `futo.network` zone to a pinned `netbird-dns` Service in front of the router pods. So any pod resolves mesh names (opc, mesh gateways) through normal cluster DNS, with no configuration for each pod.

The `netbox/cluster` module registers all of these ranges in NetBox: the vRack, the gateway ServiceCIDR and the egress CIDR. It uses the same Terraform values that allocate the ranges.

Operators point `talosctl` at the static private IP of a control plane over the node mesh. They do not use the floating VIP, because ARP for the VIP across data centers is not reliable over the route. The VIP stays the apiserver endpoint inside the cluster. By default, `kubectl` uses `kube.<mesh-domain>` through the mesh gateway. For a bootstrap or a recovery, `kubectl --server https://<cp-private-ip>:6443` connects to a control plane directly.

## Cost

All prices are in USD and match the OVH catalog. OVH lists its prices in GBP, and this guide converts them at about 1.27×. Public Cloud instances bill by the hour, and the table shows them at about 730 hours per month. The workers and the IPLB bill monthly. The vRack is free.

| Component     | Staging         | Production       | Setup (one-time) |
| ------------- | --------------- | ---------------- | ---------------- |
| Control plane | $123 (3× b3-8)  | $123 (3× b3-8)   | None             |
| Workers       | $163 (3× SYS-2) | $465 (3× Rise-2) | $221             |
| IPLB          | $20 (1 zone)    | $61 (3 zones)    | None             |
| Total / mo    | $306            | $649             | $221             |

Staging and production together run at about $955 per month. The production install also has a one-time fee of $221. These costs are within the budget of about $1,000 per month.

## Environment differences

| Parameter                       | Staging                       | Production                               |
| ------------------------------- | ----------------------------- | ---------------------------------------- |
| Cluster name                    | `o11y-staging`                | `o11y-production`                        |
| Telemetry labels                | `cluster=o11y`, `env=staging` | `cluster=o11y`, `env=prod`               |
| Workers                         | 3× `SYS-2` (`24sys022`)       | 3× `Rise-2` (`24rise02-v1`)              |
| IPLB                            | 1 zone (`gra`)                | 3 zones (`gra` + `rbx` + `sbg`), anycast |
| Private CIDR                    | `10.150.200.0/24`             | `10.150.100.0/24`                        |
| Mesh domain                     | `staging.o11y.futo.network`   | `o11y.futo.network`                      |
| Gateway ServiceCIDR (VIP `.10`) | `10.69.1.0/24`                | `10.69.0.0/24`                           |
| Pod egress CIDR                 | `10.69.3.0/24`                | `10.69.2.0/24`                           |
| NetBird objects                 | `o11y-staging-*`              | `o11y-production-*`                      |
| Flux source                     | `staging` overlay             | `production` overlay                     |
