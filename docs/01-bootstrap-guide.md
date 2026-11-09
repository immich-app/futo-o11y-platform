# Bootstrap guide

This guide builds an environment from nothing. Terragrunt builds the infrastructure, one module at a time. You then apply the Talos machine configurations that topf renders, and the `bootstrap/` tasks hand the cluster to Flux. Run every command through `mise`, so that everyone uses the same tool versions and the same 1Password credentials. The [README](../README.md) shows where each module and manifest lives, and where the state and the secrets come from.

## One-time preparation for each environment

1. Create the 1Password vault of the environment (`o11y_tf_staging` or `o11y_tf_prod`).
2. Create `.private/openstack/<env>/openrc.sh` for the OVH Public Cloud project of the environment.
3. Upload the Talos OpenStack image to the regions of the environment. Only the control planes use this image:

   ```bash
   mise run //deployment/modules/ovh/account:image:download && mise run //deployment/modules/ovh/account:image:upload
   ```

   The image contains the `qemu-guest-agent` and `netbird` extensions.

4. Do not download or upload an image for the workers. The workers are OVH BYOI (bring your own image) servers. When you order a worker, OVH pulls its bare-metal raw image from the Talos Factory.
5. Keep only `netbird` in the worker schematic. On bare metal, `qemu-guest-agent` waits for a virtio port that never appears, and the node reboots in a loop.
6. For production, delete the apex DNS records in the OVH dashboard before you apply.

## Apply order

Set the environment in your shell first:

```bash
export ENVIRONMENT=staging
export TF_VAR_env=staging
```

1. Apply the OVH module. It creates the cloud project, the vRack, the private network, the control-plane instances, the workers, the IPLB and the DNS records. The first run is slow. Each control-plane instance takes about 5 minutes, each bare-metal order takes 20 to 45 minutes, and the IPLB takes about 10 minutes.

   ```bash
   mise run //deployment/modules/ovh/account:apply
   ```

2. Apply the NetBird module. It creates the mesh objects of the environment, all named `o11y-<env>-*`:
   - The groups and the setup keys for the Talos nodes and for the routing peers in the cluster.
   - The network route to the vRack.
   - The VIP resource and the DNS zone of the mesh gateway.
   - The network for pod egress.
   - The access policies: `yucca → resource`, `yucca → talos`, `yucca → gateway` and `talos → bootstrap opc`.

   The module also writes both setup keys to the vault of the environment (`NETBIRD_TALOS_SETUP_KEY`, `NETBIRD_K8S_ROUTING_PEER_SETUP_KEY`). topf and `//bootstrap:resources` read them from there. The module connects to the 1Password Connect server of the bootstrap cluster over NetBird. For a new environment, run the first apply from your own machine.

   ```bash
   mise run //deployment/modules/netbird/cluster:apply
   ```

3. Apply the NetBox module. It registers the ranges of the environment in IPAM: the vRack, the gateway ServiceCIDR and the CIDR for pod egress. It uses the same values that the other modules allocate.

   ```bash
   mise run //deployment/modules/netbox/cluster:apply
   ```

4. Apply the Talos module. It holds only the Talos secrets bundle: the cluster CAs, keys and tokens. topf reads the bundle from the Terraform state to render the machine configurations.

   ```bash
   mise run //deployment/modules/talos/cluster:apply
   ```

5. Apply the machine configurations to the new nodes. A new node boots into maintenance mode, and it accepts an unauthenticated configuration only on its public IP, because NetBird does not run yet.

   1. Render the machine configurations into a temporary directory. The files contain the private keys of the cluster.

      ```bash
      dir="$(mktemp -d)"
      mise run //talos:render "$dir"
      ```

   2. Apply each configuration over the public IP of its node. The OVH module outputs the public IPs.

      ```bash
      mise run //deployment/modules/ovh/account:output -- -json \
        | jq -r '[.controlplane_nodes.value, .worker_nodes.value][][] | "\(.name) \(.public_ip)"' \
        | while read -r name ip; do
            talosctl apply-config --insecure --nodes "$ip" --file "$dir/$name.yaml" </dev/null \
              || echo "FAILED: $name ($ip)" >&2
          done
      ```

      The loop continues after a failed node and prints `FAILED:` with the name of the node. Read the `talosctl` error above that line.

   3. Delete the rendered files:

      ```bash
      rm -rf "$dir"
      ```

   Each node installs Talos, reboots and joins the NetBird mesh. The host firewall then closes the public network interface, except port `30443` on the workers. If `talosctl` reports `certificate required`, the node already has a configuration. If `talosctl` cannot connect, the node already has a configuration and its firewall drops the traffic, or the node is down. To change a configured node, use `mise run //talos:apply`.

6. Bootstrap the cluster. The task runs the stages below in order. Each stage is also a task of its own, and you can run each stage again without harm.

   ```bash
   mise run //bootstrap:cluster
   ```

   1. `//bootstrap:etcd` bootstraps etcd on the first control plane. It connects to the private IP of that node, so your NetBird client must have the route to the vRack. If etcd is not bootstrapped within 20 minutes, the task stops.
   2. `//bootstrap:kubeconfig --direct` writes the kubeconfig (see [Cluster access](#cluster-access)). It points the kubeconfig at the first control plane, because the mesh gateway does not exist yet.
   3. `//bootstrap:ready` waits until every node in `topf.yaml` is registered and `Ready`. If a node does not join within 20 minutes, the task stops and names it.
   4. `//bootstrap:resources` applies the namespaces, the `bootstrap-settings` ConfigMap and the bootstrap secrets. The secrets are the OVH DNS credentials for cert-manager, the NetBird routing-peer key and the 1Password Connect token for external-secrets.
   5. `//bootstrap:crds` creates the missing CRDs of the charts in `bootstrap/crds.yaml`: the Prometheus Operator CRDs and the grafana-operator CRDs. Apps that only use these CRDs need no Flux `dependsOn` on these charts. Existing CRDs belong to Flux, so the task does not change them.
   6. `//bootstrap:apps` installs CoreDNS, the Flux Operator and the FluxInstance with helmfile (`bootstrap/helmfile.yaml`). The chart versions and values come from the Flux apps, so Flux takes over the same releases.

Flux then reconciles from `kubernetes/clusters/<env>/apps.yaml`. From there, it applies the Kustomization of each app in dependency order. When the mesh gateway is up, run `mise run //bootstrap:kubeconfig` to point the kubeconfig at the mesh endpoint.

## Cluster access

This section gives you `kubectl` and `talosctl` access to a cluster that already exists. It does not need a bootstrap. You need the NetBird client and the 1Password CLI.

The cluster APIs are reachable only over the NetBird network. Run the NetBird client (`netbird up`) and join the FUTO NetBird account. The account puts your peer in the `yucca` group. The access policy then gives your peer the route to the vRack CIDR of the cluster. `kubectl` and `talosctl` can then reach the private IPs of the nodes.

Install the 1Password CLI (`op`) and sign in to the `team-futo.1password.com` account. The tasks below read the Talos secrets bundle from the Terraform state through the `//:tg` Terragrunt wrapper. The wrapper runs `op run` to inject the state credentials. Without a signed-in `op`, the tasks cannot read the state.

Run these tasks to write the kubeconfig and the talosconfig for the environment. Run only the one that you need:

```bash
export ENVIRONMENT=staging        # or production
export TF_VAR_env=$ENVIRONMENT
mise run //bootstrap:kubeconfig     # for kubectl
mise run //talos:talosconfig        # for talosctl
```

Each task writes to `.private/$ENVIRONMENT/` with mode 600. topf signs the files with the Talos secrets bundle. The kubeconfig holds a new admin certificate that expires after 12 hours. When it expires, run the task again.

The kubeconfig has one context, `o11y-<env>`. It uses the HA endpoint `kube.<mesh-zone>:6443`. The Envoy mesh gateway passes that endpoint to every apiserver with TLS passthrough. If one control plane is down, the endpoint stays up. The endpoint never loops through a NetBird routing peer.

If the mesh gateway does not exist yet, for example during a bootstrap or a recovery, run `mise run //bootstrap:kubeconfig --direct`. The kubeconfig then uses the first control plane. For one command, you can also connect to a control plane with `kubectl --server https://<cp-private-ip>:6443`. Each control-plane IP is a SAN (subject alternative name) of the apiserver certificate, so TLS works on both paths. The floating VIP `.5` works only inside the cluster, because it does not ARP across data centers.

If mise is active in the repository, it sets `KUBECONFIG` and `TALOSCONFIG` to these files for `$ENVIRONMENT`. If mise is not active, export the variables:

```bash
export KUBECONFIG=$PWD/.private/$ENVIRONMENT/kubeconfig
export TALOSCONFIG=$PWD/.private/$ENVIRONMENT/talosconfig

kubectl get nodes
talosctl -n 10.150.200.10 health   # any CP private IP. The talosconfig also lists the workers.
```

## Common operations

| Task                             | Command                                                                                                                                              |
| -------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plan/apply one module            | `mise run //deployment/modules/<m>:plan` / `mise run //deployment/modules/<m>:apply` (or `mise run :plan` from inside the module)                    |
| Plan/apply all in dep order      | `mise run //deployment:plan` / `mise run //deployment:apply`                                                                                         |
| Re-init backends                 | `mise run //deployment:init`                                                                                                                         |
| Any other terragrunt subcommand  | `mise run //:tg <args>` (runs in the current directory, for example `state rm`, `import`, `force-unlock`)                                            |
| Format HCL / Terraform           | `mise run //deployment:fmt` (`//deployment:fmt:check` reports without a change)                                                                      |
| Format everything                | `mise run //:fmt`, which also runs `//deployment:fmt` (`//:fmt:check` reports without a change. lefthook formats docs and manifests on each commit.) |
| Fetch kubeconfig / talosconfig   | `mise run //bootstrap:kubeconfig` / `mise run //talos:talosconfig` (see [Cluster access](#cluster-access))                                           |
| Diff / apply Talos configuration | `mise run //talos:diff` / `mise run //talos:apply` (append `-- --nodes-filter <regex>` for some nodes)                                               |
| Upgrade Talos or Kubernetes      | Merge the grouped Renovate PR, or bump the versions in `talos/<env>/topf.yaml` and in the tuppr upgrades together. tuppr then upgrades the nodes.    |

## Apply guardrails

- Run `mise run //talos:diff` before every apply. If the configuration of a node will change, the task exits with code 2. topf redacts the Talos secrets in each diff, and `op run` hides the NetBird key. During a key rotation, the old key can show in the diff. A rotation replaces the key in Terraform, which deletes the old key in NetBird. So the old key in the diff no longer works.
- `//talos:apply` changes one node at a time. topf shows the diff of each node and asks before it applies the change. It applies with `auto` and waits until the node is ready again before it continues.
- Talos 1.14 applies most changes without a reboot, and it no longer reports whether a change needs one. If a change needs a reboot, the nodes reboot one at a time.
- If a change needs a reboot, apply it to the elected NetBird routing peer last (`-- --nodes-filter`). A reboot of that peer drops the vRack route until NetBird elects another peer.
- Apply each change to staging first.
- An apply cannot destroy a server. The OVH control-plane instances, the bare-metal workers and the Talos machine secrets carry `prevent_destroy`. If a plan replaces or deletes one of them, the plan fails. To tear one down, remove that lifecycle rule in the same change.

## Tooling

OpenTofu and Terragrunt manage the infrastructure as code. topf renders the Talos machine configurations. helmfile installs the releases that Flux needs before it starts. mise sets the tool versions and runs the tasks. The version pins live in `.mise/config.toml` and in the lock file of each module.

When a command runs, the 1Password CLI (`op run --env-file deployment/.env`) injects the API credentials.
