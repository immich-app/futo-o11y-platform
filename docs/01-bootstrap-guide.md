# Bootstrap guide

How to stand up an environment from nothing. Terragrunt builds the infrastructure in module order. The `bootstrap/` tasks then configure Talos with topf and hand the cluster to Flux. Run everything through `mise` so tool versions and 1Password credential injection are consistent. See the [README](../README.md) for the repository layout — where each module and manifest lives, and where state and secrets come from.

## One-time prep (per environment)

1. Create the environment's 1Password vault (`o11y_tf_staging` or `o11y_tf_prod`).
2. Set up `.private/openstack/<env>/openrc.sh` for the environment's OVH Public Cloud project.
3. Upload the Talos **OpenStack** image (control planes only) to the environment's regions:

   ```bash
   mise run //deployment/modules/ovh/account:image:download && mise run //deployment/modules/ovh/account:image:upload
   ```

   This image carries the `qemu-guest-agent` + `netbird` schematic.

4. Workers need **no download or upload** — they are OVH BYOI and pull the bare-metal raw straight from the Talos Factory at order time. The worker schematic must stay **netbird-only**: `qemu-guest-agent` on bare metal blocks on a virtio port that never appears and reboot-loops the node.
5. For production: delete the apex DNS records via the OVH dashboard before applying.

## Apply order

Set the environment in the shell first:

```bash
export ENVIRONMENT=staging
export TF_VAR_env=staging
```

1. **OVH** — cloud project, vRack, private network, CP instances, workers, IPLB, DNS. First-time runs are slow (CP instances ~5 min each, bare-metal orders 20–45 min each, IPLB ~10 min).

   ```bash
   mise run //deployment/modules/ovh/account:apply
   ```

2. **NetBird** — the per-environment mesh objects (all named `o11y-<env>-*`): groups and setup keys for the Talos nodes and the in-cluster routing peers, the vRack network route, the mesh-gateway VIP resource and DNS zone, the pod-egress network, and the access policies (`yucca → resource`, `yucca → talos`, `yucca → gateway`, `talos → bootstrap opc`). It writes both setup keys to the environment vault (`NETBIRD_TALOS_SETUP_KEY`, `NETBIRD_K8S_ROUTING_PEER_SETUP_KEY`), where topf and `//bootstrap:resources` read them. It reaches the bootstrap cluster's 1Password Connect over NetBird, so run its first apply from your own machine.

   ```bash
   mise run //deployment/modules/netbird/cluster:apply
   ```

3. **NetBox** — registers the environment's ranges (vRack, gateway ServiceCIDR, pod-egress CIDR) in IPAM, from the same values the other modules allocate.

   ```bash
   mise run //deployment/modules/netbox/cluster:apply
   ```

4. **Talos secrets.** This module holds only the Talos secrets bundle (cluster CAs, keys and tokens). topf reads it from the state to render the machine configs.

   ```bash
   mise run //deployment/modules/talos/cluster:apply
   ```

5. **Cluster.** This task runs the stages below in order. Each stage is also a task of its own, and you can run each stage again safely.

   ```bash
   mise run //bootstrap:cluster
   ```

   1. `//bootstrap:nodes` renders the machine configs with topf and applies them over the public IPs, because the nodes are in maintenance mode and NetBird is not running yet. Nodes that already have a config are skipped.
   2. `//bootstrap:etcd` bootstraps etcd on the first control plane. It reaches the node on its private IP, so your NetBird client must route to the vRack. The nodes join the mesh after they install. The host firewall then closes the public NIC (everything except `:30443` on workers).
   3. `//talos:kubeconfig` writes the kubeconfig (see [Cluster access](#cluster-access)). The task then points it at the first control plane, because the mesh gateway does not exist yet.
   4. `//bootstrap:ready` waits until every node is registered and `Ready`.
   5. `//bootstrap:resources` applies the namespaces, the `bootstrap-settings` ConfigMap and the bootstrap secrets (cert-manager OVH DNS credentials, the NetBird routing-peer key, the 1Password Connect token for external-secrets).
   6. `//bootstrap:apps` installs CoreDNS, the Flux Operator and the FluxInstance with helmfile (`bootstrap/helmfile.yaml`). Chart versions and values come from the Flux apps, so Flux takes over the same releases.
   7. `//talos:kubeconfig` writes the kubeconfig again with the mesh endpoint.

Flux then reconciles from `kubernetes/clusters/<env>/apps.yaml`, fanning out to the per-app Kustomizations in dependency order.

## Cluster access

How to get `kubectl` / `talosctl` access to an **existing** cluster (no bootstrap required).

**Prerequisites:**

- **NetBird** — the cluster APIs are reachable only over the NetBird network, so your host must be running the NetBird client (`netbird up`) and joined to the FUTO NetBird account, which places your peer in the `yucca` group. The access policy then distributes the route to the cluster's vRack CIDR, so `kubectl`/`talosctl` can reach the nodes' private IPs.
- **1Password CLI (`op`)** — installed and signed in to the `team-futo.1password.com` account. The tasks below read the Talos secrets bundle from the Terraform state through the `//:tg` terragrunt wrapper, which wraps `op run` to inject the state credentials. Without an authenticated `op`, they cannot read the state.

**Fetch the configs.** Two tasks pull `kubeconfig` and `talosconfig` for the environment (run whichever you need):

```bash
export ENVIRONMENT=staging        # or production
export TF_VAR_env=$ENVIRONMENT
mise run //talos:kubeconfig         # for kubectl
mise run //talos:talosconfig        # for talosctl
```

Each writes to `.private/$ENVIRONMENT/` (mode 600). topf signs the files from the Talos secrets bundle. The kubeconfig carries a new admin certificate that expires after 12 hours, so run the task again when it expires.

The kubeconfig has one context, `o11y-<env>`. It uses the HA endpoint `kube.<mesh-zone>:6443`, which the Envoy mesh gateway fronts with TLS passthrough to every apiserver. That endpoint survives any single control plane being down, and it never hairpins through a NetBird routing peer. Before the mesh gateway exists (bootstrap, DR), reach a control plane directly with `kubectl --server https://<cp-private-ip>:6443`. Every control-plane IP is an apiserver cert SAN, so TLS validates on both paths. The floating VIP `.5` works only inside the cluster, because it does not ARP across DCs.

**Point your tools at them.** When mise is active in the repository, it sets `KUBECONFIG` and `TALOSCONFIG` to these files for `$ENVIRONMENT`. Otherwise, export them:

```bash
export KUBECONFIG=$PWD/.private/$ENVIRONMENT/kubeconfig
export TALOSCONFIG=$PWD/.private/$ENVIRONMENT/talosconfig

kubectl get nodes
talosctl -n 10.150.200.10 health   # any CP private IP; the talosconfig also lists the workers
```

## Common operations

| Task                            | Command                                                                                                                                |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| Plan/apply one module           | `mise run //deployment/modules/<m>:plan` / `mise run //deployment/modules/<m>:apply` (or `mise run :plan` from inside the module)      |
| Plan/apply all in dep order     | `mise run //deployment:plan` / `mise run //deployment:apply`                                                                           |
| Re-init backends                | `mise run //deployment:init`                                                                                                           |
| Any other terragrunt subcommand | `mise run //:tg <args>` (runs in the current directory, e.g. `state rm`, `import`, `force-unlock`)                                     |
| Format HCL / Terraform          | `mise run //deployment:fmt`                                                                                                            |
| Format docs and manifests       | `mise run //:fmt` (`//:fmt:check` to verify; lefthook runs it per commit)                                                              |
| Fetch kubeconfig / talosconfig  | `mise run //talos:kubeconfig` / `mise run //talos:talosconfig` (see [Cluster access](#cluster-access))                                 |
| Diff / apply Talos configs      | `mise run //talos:diff` / `mise run //talos:apply` (append `-- --nodes-filter <regex>` for some nodes)                                 |
| Upgrade Talos or Kubernetes     | Merge the grouped Renovate PR (or bump the versions in `talos/<env>/topf.yaml` and the tuppr upgrades together); tuppr rolls the nodes |

## Apply guardrails

- **Run `mise run //talos:diff` before every apply.** It exits with code 2 when a node's config would change, and it prints each diff with the secrets redacted.
- **`//talos:apply` changes one node at a time.** topf shows each node's diff and asks before it applies. It applies with `auto` and waits until the node is ready again before it continues. Talos 1.14 applies most changes without a reboot, and it no longer reports whether a change needs one. If a change needs a reboot, the nodes reboot one at a time. Apply such a change to the elected NetBird routing peer last (`-- --nodes-filter`), because its reboot drops the vRack route until another peer is elected. Apply the change to staging first.
- **Servers cannot be destroyed by an apply.** The OVH control-plane instances, the bare-metal workers, and the Talos machine secrets carry `prevent_destroy`; a plan that would replace or delete one fails instead. Tearing one down deliberately means removing that lifecycle rule in the same change.

## Tooling

- **OpenTofu** + **Terragrunt** for IaC; **topf** for the Talos machine configs; **helmfile** for the pre-Flux releases; **mise** drives tool versions and task wrappers. Version pins live in `.mise/config.toml` and each module's lock file.
- **1Password CLI** (`op run --env-file deployment/.env`) injects API credentials at invocation time.
