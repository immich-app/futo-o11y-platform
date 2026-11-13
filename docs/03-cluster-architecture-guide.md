# Cluster architecture guide

This guide describes how the cluster is built: the Talos operating system, the Kubernetes layer, and the Flux GitOps layer that manages everything on top.

## Talos

Every node runs Talos Linux. The cluster uses the flannel CNI and runs kube-proxy in nftables mode. Multus wraps flannel, so a pod can opt in to secondary interfaces.

### Image schematics

Control planes and workers use different Talos Factory schematics on purpose:

| Node type     | Platform               | Schematic                      |
| ------------- | ---------------------- | ------------------------------ |
| Control plane | OVH Public Cloud (KVM) | `netbird` + `qemu-guest-agent` |
| Worker        | Bare metal             | `netbird` only                 |

On bare metal, `qemu-guest-agent` blocks the boot. It waits for a virtio-serial port that does not exist, and the node reboots in a loop. The control-plane image is an OpenStack image, uploaded to OVH glance once. Workers use BYOI (bring your own image) and fetch their raw image from the Factory at order time.

### Machine configuration

- topf renders the configuration of every node from `talos/`. Each environment has one `talos/<env>/topf.yaml` with its nodes, versions and network values. Both environments share the patches in `talos/patches/`. The Talos secrets bundle is `TALOS_SECRETS` in Infisical, in the `observability <env>:/talos` folder, which the cluster's own Infisical identity cannot read. topf reads and stores the bundle through `talos/bin/talos-secrets`, so the repository holds no secret.
- The control-plane endpoint is the floating VIP (`10.150.200.5`). The SANs of the apiserver certificate include the VIP and the private IP of every control plane. The private IPs are the direct, break-glass path. They also include `kube.<mesh-domain>`. The mesh gateway serves this HA endpoint through TLS passthrough, and `kubectl` uses it by default.
- `bootstrap/` installs CoreDNS before Flux, because Flux needs cluster DNS for its first reconcile. `bootstrap/` installs the chart with helmfile from the Flux app in `kubernetes/apps/base/coredns`, and Flux then manages the same release. The CoreDNS of Talos is off, and the chart owns the `kube-dns` Service. The `clusterDNS` value in the kubelet configuration pins the IP of that Service. The Corefile adds a `futo.network` zone and forwards it to the NetBird mesh DNS (see the infrastructure guide).
- The configuration pins the node IP of the kubelet to the vRack subnet. Without the pin, the kubelet detects the node IP itself. A host address that sorts lower, such as the Multus egress bridge, then takes the InternalIP of the node. This breaks the traffic from the apiserver to the kubelet.
- The metrics endpoints of kube-controller-manager, kube-scheduler, and etcd bind to all interfaces, not to localhost, so that VMAgent on a worker can scrape them. The host firewall keeps these ports private. The controller-manager and scheduler endpoints use authenticated HTTPS. The etcd endpoint uses plain HTTP, so the firewall is its only protection.
- kube-proxy answers NodePorts on every interface, not only on the primary vRack IP of the node. This lets the IPLB reach Envoy on the public NIC of the workers. The metrics endpoint of kube-proxy is bound in the same way, for scraping. The generated kube-proxy DaemonSet for the whole cluster contains this configuration.
- Talos sends its service logs and the kernel ring buffer to the `talos-logs` relay, a Fluent Bit DaemonSet (`kubernetes/apps/base/talos-logs`). Talos can only send JSON lines over TCP or UDP, and VictoriaLogs reads only syslog on a raw socket, so the relay translates. Talos sends from the host network namespace, where cluster DNS does not resolve. The machine configuration (`talos/patches/all/07-logging.yaml`) therefore holds the pinned ClusterIP of the relay Service. The Service uses `internalTrafficPolicy: Local`, so kube-proxy delivers the lines of a node to the relay pod on that node.
- The configuration pins the VXLAN endpoint of flannel to the vRack interface. Without the pin, flannel uses the public NIC by default. The host firewall then drops the east-west pod traffic, which is pod traffic between nodes.

### Upgrades

tuppr (`kubernetes/apps/base/tuppr`) upgrades Talos and Kubernetes from inside the cluster, one node at a time. The `TalosUpgrade` and the `KubernetesUpgrade` in `kubernetes/apps/base/tuppr-upgrades` hold the target versions. Production pins its own versions in `kubernetes/apps/production/tuppr-system/patches/`.

Before an upgrade, tuppr makes sure that the nodes, the Postgres clusters and Dragonfly are healthy. It also makes sure that the VictoriaMetrics, VictoriaLogs and VictoriaTraces clusters are healthy. A Talos upgrade does these checks again before each node. A Kubernetes upgrade does them only before it starts. While a Kubernetes upgrade runs, watch those workloads.

The versions in `talos/<env>/topf.yaml` must match the versions that tuppr rolls out. If they differ, the next topf apply renders the old Kubernetes component images. For each environment, Renovate puts the Talos versions in one PR and the Kubernetes versions in another PR.

tuppr connects to the Talos API with an `os:admin` talosconfig. Talos gives that talosconfig only to the `tuppr-system` namespace (`talos/patches/control-plane/05-talos-api-access.yaml`).

### Worker storage

The staging workers have two NVMe drives, and the production workers have three. Talos divides the system disk into a fixed EPHEMERAL partition and a growing hostpath UserVolume. The EPHEMERAL partition holds the container image cache and the working directories of the kubelet. A factory reset wipes it. The hostpath UserVolume backs the default `openebs-system-disk` StorageClass. This StorageClass holds the vmagent buffers, the vmselect cache, the CloudNativePG Postgres clusters of Grafana and GlitchTip, the GlitchTip Dragonfly, and the app configuration.

Each other NVMe drive is a separate UserVolume that keeps the storage-heavy workloads out of the general pool:

- `local-hostpath` backs the `openebs-spare-disk` StorageClass. It holds VictoriaMetrics `vmstorage` in both environments, and on staging also VictoriaLogs and VictoriaTraces.
- On production only, `local-hostpath-2` backs the `openebs-spare-disk-2` StorageClass. It holds VictoriaLogs and VictoriaTraces.

The UserVolumes select the spare disks by their exact model. If a re-provision runs on different hardware, it fails with an error and does not take the wrong disk. Control planes use the default Talos layout.

### Host firewall

Every node denies ingress by default. The host drops all traffic that the table below does not allow:

| Service                    | Port(s)                | Allowed sources                       |
| -------------------------- | ---------------------- | ------------------------------------- |
| apid                       | 50000/tcp              | vRack + NetBird peers + pod CIDR      |
| trustd                     | 50001/tcp              | vRack                                 |
| kube-apiserver (CPs)       | 6443/tcp               | vRack + NetBird peers `10.254.0.0/15` |
| etcd (CPs)                 | 2379–2380/tcp          | vRack                                 |
| kubelet                    | 10250/tcp              | vRack + pod CIDR `10.244.0.0/16`      |
| flannel VXLAN              | 4789/udp               | vRack                                 |
| Spegel registry (workers)  | 30020/tcp              | vRack                                 |
| Envoy ingress (workers)    | 30443/tcp              | `10.108.0.0/14` (IPLB NAT range only) |
| CP component metrics (CPs) | 10257, 10259, 2381/tcp | vRack + pod CIDR                      |
| Node metrics (all nodes)   | 10249, 9100/tcp        | vRack + pod CIDR                      |

The rules for `apid` (for tuppr), `kubelet` and the metrics ports also allow the pod CIDR. Traffic from a pod to the IP of its own node skips the flannel masquerade, so it keeps the pod IP as its source. A rule for the vRack alone drops that traffic.

Operators send `talosctl`/`kubectl` traffic through the NetBird route. This traffic arrives with the vRack IP of a routing peer as its source, because the peer masquerades it. The vRack rule allows it. Traffic to the vRack IP of the elected routing peer itself does not go through the forward path. The peer delivers it locally, and the traffic keeps the NetBird source address of the operator. For this reason, `apid` and `kube-apiserver` also allow the NetBird peer range.

Without the NetBird peer range in these rules, operators cannot reach the elected router at its own IP. On the NetBird side, the matching accept rule is the `yucca → talos` peer policy, because resource policies only program forwarding.

## Kubernetes

Kubernetes runs with the flannel CNI and kube-proxy in nftables mode. Multus runs as a meta-CNI, which is a CNI plugin that calls other CNI plugins. Multus wraps the flannel configuration. A pod with the `k8s.v1.cni.cncf.io/networks` annotation gets extra interfaces from `NetworkAttachmentDefinition` objects. Today the only one is `netbird-egress`, the egress leg of the mesh (see the infrastructure guide). Multus does not change pods without the annotation.

Spegel runs as a peer-to-peer mirror for the image registry. The containerd on each node pulls layers from its peers before it uses the upstream registry. This requires `discard_unpacked_layers = false` in the containerd configuration of the workers.

Control-plane scraping is set up from end to end. The component metrics endpoints bind to interfaces other than localhost (see Machine configuration above). The host firewall limits them to the vRack and the pod CIDR. VMAgent scrapes kube-controller-manager, kube-scheduler, etcd, kube-proxy, and the node-exporter DaemonSet.

## Flux GitOps

Flux v2 manages everything above the OS. The manifests are reusable bases plus overlays for each environment:

- `kubernetes/apps/base/<app>/` is the single home of an app. `ks.yaml` is its Flux Kustomization, with the `dependsOn` order and the health checks. `app/` is what that Kustomization deploys: the chart source and the manifests. Both environments reconcile the same definition. `dependsOn` is for apps that need a running controller, a webhook or an object from another app. The bootstrap creates the CRDs that some apps only use (`bootstrap/crds.yaml`). Those apps then do not wait for the charts that ship the CRDs.
- `kubernetes/apps/<env>/<ns>/` is the overlay for one namespace. It holds a kustomization that lists the base apps that run in the namespace, and the Namespace object itself. If an environment needs an app to differ from `base/`, the overlay holds one patch file for that app in its `patches/` folder. Today the only such patches are the version pins of production.
- `kubernetes/components/` holds shared kustomize Components. Today the only one is `replacements/`, and every overlay includes it. It copies the name of the overlay Namespace into the `spec.targetNamespace` of each Flux Kustomization. As a result, an app deploys into the namespace that lists it, and `base/` stays independent of any namespace. Because of this, put an app in the folder of the namespace that holds its resources. For example, `mesh-gateway-api` is under `default/`, because its TLSRoute must be in the same namespace as the `default/kubernetes` Service that it routes to. Every namespaced resource gets the overlay namespace. This replaces any namespace that the resource sets itself. If an app needs resources in a different namespace, it needs a `reject` entry in the component.

- `kubernetes/clusters/<env>/apps.yaml` is the `cluster-apps` entry point. The Flux Instance points at it.

`kubernetes/clusters/<env>/apps.yaml` defines the HelmRelease lifecycle defaults for the whole cluster, in one place. The defaults are `crds: CreateReplace` on install and upgrade, `cleanupOnFail`, and `RemediateOnFailure` with retries. `cluster-apps` appends them to every child Kustomization with a JSON6902 `add /spec/patches/-`. Each child Kustomization then applies them to every HelmRelease that it renders. A single release declares only the values that differ from the defaults.

The per-app override patches are in the same list. An append keeps them, but a strategic merge replaces the whole list and erases every override without an error. Every base `ks.yaml` sets `patches: []`, so the append always has a list to add to. If a new app does not set it, the build for the environment fails with an error.

### Environment overrides

To change an app, an overlay adds one patch file for that app to its `patches/` folder. The overlay also lists the file in its `patches:` section. The overlay then reads as a list of apps and their changes.

Each file patches the Flux Kustomization of the app. The patch adds a `spec.patches` override for each resource that must differ from `base/`. The patch must go on the Kustomization, because Flux renders the resources of the app from `base/`. The overlay build never renders them.

Today the production overrides are version pins, and staging has a few permanent overrides, such as the smaller VictoriaMetrics sizing. Production pins the chart versions and the version of the CloudNativePG Postgres image. Staging uses `base/` directly and follows its versions. A new version can then run in staging for a time before production moves to it.

OCI chart refs pin a tag and its digest. Flux gives the digest precedence. If a production patch carries only the tag, the digest from `base/` overrides the environment pin, and nothing reports it. For this reason, the production patches must carry both. The `Promote` workflow updates the tag and the digest of each production pair together, from the pair in `base/`. The built-in flux manager of Renovate maintains the pairs in `base/`, and Renovate moves the Talos and Kubernetes versions of both environments.

### Promotion

A plain change to `base/` reaches both environments at once, except where production overrides it, which today means the version pins. A change that must run in staging first goes into a staging override instead, with a header comment of the form `# promote-after: YYYY-MM-DD`. A staging override without that comment is a permanent difference between the environments, and nothing promotes it.

The `Promote` workflow (`.github/workflows/promote.yaml`) runs every Monday and on demand. It runs the procedure in `.agents/skills/promote/SKILL.md`, which an agent on a local checkout can follow the same way. It folds each staging override whose date passed into base and deletes the override. It then sets every production pin to the value in base, except the Talos and Kubernetes versions, which Renovate moves together with `talos/<env>/topf.yaml`. It runs the flate tests and opens one pull request from the branch `promote/production`. Renovate does not propose production updates for the pins the workflow owns. A failed flate test stops the run before the pull request. The pull request goes through the normal review, and nothing merges on its own. The workflow needs the `ANTHROPIC_API_KEY` secret and the app secrets that mint the pull request token.

This guide does not list component versions, because they change all the time. The manifests are the source of truth.

### Configuration substitution

`base/` does not hardcode the values for each environment, and the overlays do not patch them in. Instead, `cluster-apps` has one patch that targets every child Kustomization. The patch adds a `postBuild.substituteFrom` that points at two ConfigMaps. The envsubst of Flux resolves the values at apply time. The prefix of a value tells you who owns it:

- `cluster-settings` (`CLUSTER_*`) holds the values that git owns. It is committed in `kubernetes/clusters/<env>/`. It holds `CLUSTER_APP_DOMAIN` and the telemetry identity pair `CLUSTER_NAME`/`CLUSTER_ENV`. It also holds the retention and storage class of VictoriaMetrics and the service CIDR of the bootstrap cluster, which the mesh egress routes. `CLUSTER_NAME` and `CLUSTER_ENV` set the `cluster` and `env` labels (see the [shipping guide](05-shipping-metrics-guide.md)).
- `bootstrap-settings` (`BOOTSTRAP_*`) holds values that Terraform owns and that must match the infrastructure. These values are the mesh DNS zone, the gateway VIP of NetBird, its ServiceCIDR, and its egress CIDR and gateway. `mise run //bootstrap:resources` creates the ConfigMap in the cluster from the `bootstrap_settings` output of `terraform/netbird`. The entry is `optional`, because offline renderers such as the flate CI job cannot read a ConfigMap that exists only in the cluster. If the ConfigMap is missing, the apps that need it still fail at apply.

As a result, each value that differs between environments lives in one place only: in git or in Terraform. The overlays do not copy it. Only the versions still have a patch in each environment. With the `flate` CLI, you can examine a rendered object exactly as Flux produces it.
