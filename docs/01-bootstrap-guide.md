# Bootstrap guide

This guide builds an environment from nothing: no servers, no Terraform state and no cluster. It covers an environment that the repository already defines, `staging` or `production`, with its `talos/<env>/` and `kubernetes/clusters/<env>/` directories. Terragrunt builds the infrastructure, one module at a time. You then apply the Talos machine configurations that topf renders, and the `bootstrap/` tasks hand the cluster to Flux. Run every command through `mise`, so that everyone uses the same tool versions and the same Infisical credentials. The [README](../README.md) shows where each module and manifest lives.

## Before you start

You need these tools and sessions on your machine:

1. Install the tools: run `mise install` in the repository. mise pins every tool, among them OpenTofu, Terragrunt, topf, talosctl, kubectl, helmfile and the Infisical CLI.
2. Join the NetBird mesh: run the NetBird client (`netbird up`) and join the FUTO NetBird account. Infisical and the cluster APIs are reachable only over the mesh. See [Cluster access](#cluster-access).
3. Sign in to Infisical once, while you are on the mesh: `infisical login --domain https://infisical.futo.network`. Every task reads its credentials with this session.
4. Make sure that you can read and write the `observability` Infisical project in the environment. core-infra-tf manages the project, its environments, its folders and its members.

core-infra-tf also provides the values in this table before the first apply. If a value is missing, the tasks fail. They do not invent one.

| Infisical folder           | Values                                                                                                                                                                                                 |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `observability global:/tf` | The Terraform state bucket (`TF_STATE_S3_*`), the OVH API keys (`OVH_*`), `ROOTLY_ZULIP_WEBHOOK`, and the manual items `FUTO_BOOTSTRAP_RELEASES_S3_READER__*` and `FMEET_O11Y_REGISTRY_DEPLOY_TOKEN_*` |
| `observability <env>:/ci`  | The Universal Auth client ID and secret of the cluster (`INFISICAL_K8S_CLIENT_ID_O11Y_<ENV>`, `INFISICAL_K8S_CLIENT_SECRET_O11Y_<ENV>`)                                                                |
| `shared global:/tf`        | `NETBIRD_TF_PAT`, `NETBOX_URL`, `NETBOX_API_TOKEN`, `ROOTLY_API_TOKEN`, `FUTO_NETWORK_DNS_CLOUDFLARE_API_TOKEN`, `FUTO_ZITADEL_OAUTH_CLIENT_ID_GRAFANA_O11Y`                                           |
| `shared <env>:/tf`         | `O11Y_VICTORIAMETRICS_VMAUTH_PASSWORD`, `O11Y_VICTORIALOGS_CLIENT_TOKEN`                                                                                                                               |

Everything else is written during the bootstrap, so do not create it by hand:

- The Terraform modules write the NetBird setup keys, the GlitchTip S3 credentials and the Rootly alert and heartbeat URLs to `observability <env>:/tf`.
- The NetBird module writes the CI setup key to `observability <env>:/github`, which Infisical syncs to the Actions secrets of this repository.
- topf stores the Talos secrets bundle in `observability <env>:/talos`.
- The cluster generates its passwords and the Rootly service-account token, and it stores them in `observability <env>:/k8s`. It also publishes the vmauth URLs for the other clusters to `shared <env>:/tf`.

## Apply order

Set the environment in your shell first:

```bash
export ENVIRONMENT=staging
```

If `ENVIRONMENT` is unset, the Terraform, Talos and bootstrap tasks stop with an error.

Steps 1 to 5 apply the Terraform modules in their dependency order. If the OpenStack upload user of step 2 already exists, `mise run //terraform:apply` applies all five modules in the same order.

1. Apply the Rootly module. It creates the alert sources, the services, the heartbeats, the Zulip workflows and the status page. It writes the alert and heartbeat URLs to Infisical. The OVH module reads the DNS records of the status page from it.

   ```bash
   mise run //terraform/rootly:apply
   ```

2. Apply the OVH module. It creates the cloud project, the vRack, the private network, the control-plane image, the control-plane instances, the workers, the IPLB and the DNS records. In production, delete the apex DNS records in the OVH dashboard before the first apply.

   The control planes boot from a Talos OpenStack image that the module uploads to each control-plane region. The OpenStack user that uploads it is part of the module, and its password exists only after that user exists. So a new environment applies in two steps:
   1. Create only the cloud project and the OpenStack user:

      ```bash
      mise run //terraform/ovh:apply -- -target=ovh_cloud_project_user.image
      ```

   2. Apply the whole module. It downloads the image from the Talos Factory, decompresses it, and uploads 4.4 GiB to each region from your machine. Each upload can take an hour, and the regions upload at the same time. The decompressed image stays in `.terraform/image_cache` in the Terragrunt working directory of the module. If an apply stops during the download, delete that directory before you run the apply again, because the provider reuses a partial file. The rest of the first run is slow too. Each control-plane instance takes about 5 minutes, each bare-metal order takes 20 to 45 minutes, and the IPLB takes about 10 minutes.

      ```bash
      mise run //terraform/ovh:apply
      ```

   The image name comes from `talos_version` and `talos_schematic_id` in the OVH module. Renovate does not bump them, because a bump uploads the image again. Bump `talos_version` by hand at least once per Talos minor, so that tuppr can upgrade a new node to the cluster version. After a change to either value, the next apply uploads the new image, and then it deletes the old one. The workers need no upload. They are OVH BYOI (bring your own image) servers, and OVH pulls their bare-metal image from the Talos Factory when you order them. Keep only `netbird` in the worker schematic. On bare metal, `qemu-guest-agent` waits for a virtio port that never appears, and the node reboots in a loop.

3. Apply the NetBird module. It creates the mesh objects of the environment, all named `o11y-<env>-*`:
   - The groups and the setup keys for the Talos nodes, for the routing peers in the cluster, and for CI.
   - The network route to the vRack.
   - The VIP resource and the DNS zone of the mesh gateway. external-dns fills the zone with the records of the mesh routes.
   - The service user and the token that external-dns uses to write those records.
   - The network for pod egress.
   - The access policies, among them `yucca → resource`, `yucca → talos`, `yucca → gateway` and `talos → bootstrap`.

   The module also writes the Talos and routing-peer setup keys to the environment in the `observability` Infisical project (`NETBIRD_TALOS_SETUP_KEY`, `NETBIRD_K8S_ROUTING_PEER_SETUP_KEY`). topf and `//bootstrap:resources` read them from there. For a new environment, run the first apply from your own machine.

   ```bash
   mise run //terraform/netbird:apply
   ```

   The module also writes the CI setup key to `observability <env>:/github`, as `NETBIRD_O11Y_CI_SETUP_KEY_PROD` or `NETBIRD_O11Y_CI_SETUP_KEY_STAGING`. It creates an Infisical secret sync that pushes that folder to the Actions secrets of this repository, so the plan workflow can join the mesh.

   The sync uses the immich-app GitHub connection, which an admin made in the Infisical UI with the Infisical GitHub App. The app's installation must have access to this repository, with the permission Secrets set to read and write. The CI plan identities can read the sync because core-infra-tf grants them read on secret syncs (`secret_syncs` in `infisical/instance/access.tf`). After the apply, open the sync in the `observability` project and make sure that its status shows success.

   In production, the folder also holds `OPENROUTER_API_KEY` for the Promote workflow. An Infisical secret rotation writes it, and the Terraform provider cannot manage that rotation. The rotation needs the secret rotation feature in the Infisical license. Create it once in the UI, in the `observability` project:
   1. Add a secret rotation of the type OpenRouter API Key, with the OpenRouter connection (`b2b5f94c-0e7a-45e5-b72d-ff744b5e107d`) and a rotation interval of 30 days.
   2. Set the key name to `futo-o11y-platform-promote`, the limit to 100 USD and the limit reset to monthly.
   3. Map the API key to `OPENROUTER_API_KEY` in the `prod` environment, in `/github`.

   Each rotation creates a new key and updates the secret, and the sync pushes the new value to GitHub. The key it replaces stays valid until the next rotation, which revokes it. To retire a leaked key at once, rotate twice.

4. Apply the NetBox module. It registers the ranges of the environment in IPAM: the vRack, the gateway ServiceCIDR and the CIDR for pod egress. It uses the same values that the other modules allocate.

   ```bash
   mise run //terraform/netbox:apply
   ```

5. Apply the GlitchTip module. It creates the S3 bucket for uploads and its credentials, and it writes them to Infisical.

   ```bash
   mise run //terraform/glitchtip:apply
   ```

6. Nothing to apply for the Talos secrets bundle: the cluster CAs, keys and tokens. It lives in Infisical as `TALOS_SECRETS` in the `observability <env>:/talos` folder. In a new environment, the first stage of step 8 finds no bundle when it writes the talosconfig. topf then asks whether to generate one, and `talos/bin/talos-secrets` stores it in Infisical. Answer yes only in a new environment.

7. Nothing to run by hand for the machine configurations: the first stage of the bootstrap in step 8 applies them. A new node boots into maintenance mode, and it accepts an unauthenticated configuration only on its public IP, because NetBird does not run yet. The stage reads the public IPs from the outputs of the OVH module. It renders the configurations into a temporary directory, and it deletes them again, because the files contain the private keys of the cluster. Each node then installs Talos, reboots and joins the NetBird mesh. The host firewall then closes the public network interface, except port `30443` on the workers. A configured node answers on its private IP, so the stage skips it. The node names in `talos/<env>/topf.yaml` and in the OVH outputs must match, or the stage stops. To change a configured node, use `mise run //talos:apply <node>`.

8. Bootstrap the cluster. The task runs the stages below in order. Each stage is also a task of its own, and you can run each stage again without harm.

   ```bash
   mise run //bootstrap:cluster
   ```

   1. `//bootstrap:nodes` applies the machine configurations to the nodes in maintenance mode, as step 7 describes. The stage tries every pending node, and then it stops the bootstrap if one failed. A node that failed a moment after its apply is not on the mesh yet. A node that cannot be reached is down. Resolve the failures, then run `mise run //bootstrap:cluster` again.
   2. `//bootstrap:etcd` bootstraps etcd on the first control plane. It connects to the private IP of that node, so your NetBird client must have the route to the vRack. If the etcd bootstrap does not complete within 20 minutes, the task stops.
   3. `//bootstrap:kubeconfig --direct` writes the kubeconfig (see [Cluster access](#cluster-access)). It points the kubeconfig at the first control plane, because the mesh gateway does not exist yet.
   4. `//bootstrap:ready` waits until every node in `topf.yaml` is registered and `Ready`. If a node does not join within 20 minutes, the task stops and names it.
   5. `//bootstrap:resources` applies the namespaces, the `bootstrap-settings` ConfigMap and the bootstrap Secrets in `bootstrap/kustomize`, filled from the `observability` Infisical project. The Secrets are the NetBird routing-peer key and the Infisical client credentials for external-secrets. Every other Secret comes from an ExternalSecret, except the ones an operator creates, such as the `grafana-rootly-token` of the grafana-operator.
   6. `//bootstrap:crds` creates the missing CRDs of the charts in `bootstrap/crds.yaml`: the Prometheus Operator CRDs and the grafana-operator CRDs. Apps that only use these CRDs need no Flux `dependsOn` on these charts. Existing CRDs belong to Flux, so the task does not change them.
   7. `//bootstrap:apps` installs CoreDNS, the Flux Operator and the FluxInstance with helmfile (`bootstrap/helmfile.yaml`). The chart versions and values come from the Flux apps, so Flux takes over the same releases.
   8. `//bootstrap:mesh` waits until `kube.<mesh-zone>:6443` answers. Flux brings that endpoint up with the mesh gateway. If it does not answer within 30 minutes, the task stops.
   9. `//bootstrap:kubeconfig` points the kubeconfig at the mesh endpoint.

   Flux reconciles from `kubernetes/clusters/<env>/apps.yaml` as soon as stage 7 completes. From there, it applies the Kustomization of each app in dependency order. On its first sync, the cluster generates its passwords and stores them in `observability <env>:/k8s`.

9. Finish the parts that have no API:
   1. When Grafana is up in production, install the token of the `rootly` service account in Rootly, as [Alerting](06-dashboards-and-alerts-guide.md#alerting) describes. Rootly holds one Grafana integration, and it points at production.
   2. When GlitchTip is up, set up its sign-in, as [GlitchTip](04-application-architecture-guide.md#glitchtip) describes. GlitchTip keeps its Zitadel provider in its database.

## Cluster access

This section gives you `kubectl` and `talosctl` access to a cluster that already exists. It does not need a bootstrap. You need the NetBird client and the Infisical CLI.

The cluster APIs are reachable only over the NetBird network. Run the NetBird client (`netbird up`) and join the FUTO NetBird account. The account puts your peer in the `yucca` group. The access policy then gives your peer the route to the vRack CIDR of the cluster. `kubectl` and `talosctl` can then reach the private IPs of the nodes.

The tasks below read the Talos secrets bundle from Infisical, so you need an Infisical session. Sign in once with `infisical login --domain https://infisical.futo.network` while you are on the mesh. The Terragrunt, Talos and bootstrap tasks all use this session. In CI, the plan job signs in with its GitHub OIDC token instead.

Run these tasks to write the kubeconfig and the talosconfig for the environment. Run only the one that you need:

```bash
export ENVIRONMENT=staging        # or production
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

| Task                             | Command                                                                                                                                             |
| -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| Plan/apply one module            | `mise run //terraform/<m>:plan` / `mise run //terraform/<m>:apply` (or `mise run :plan` from inside the module)                                     |
| Plan/apply all in dep order      | `mise run //terraform:plan` / `mise run //terraform:apply`                                                                                          |
| Re-init backends                 | `mise run //terraform:init`                                                                                                                         |
| Any other terragrunt subcommand  | `mise run //:tg <args>` (runs in the current directory, for example `state rm`, `import`, `force-unlock`)                                           |
| Format HCL / Terraform           | `mise run //terraform:fmt` (`//terraform:fmt:check` reports without a change)                                                                       |
| Format everything                | `mise run //:fmt`, which also runs `//terraform:fmt` (`//:fmt:check` reports without a change. lefthook formats docs and manifests on each commit.) |
| Fetch kubeconfig / talosconfig   | `mise run //bootstrap:kubeconfig` / `mise run //talos:talosconfig` (see [Cluster access](#cluster-access))                                          |
| Diff / apply Talos configuration | `mise run //talos:apply --dry-run <node>...` / `mise run //talos:apply <node>...` (each `<node>` is a host in `talos/$ENVIRONMENT/topf.yaml`)       |
| Upgrade Talos or Kubernetes      | Merge the grouped Renovate PR, or bump the versions in `talos/<env>/topf.yaml` and in the tuppr upgrades together. tuppr then upgrades the nodes.   |

## Apply guardrails

- `//talos:apply` takes one or more node names, the hosts in `talos/$ENVIRONMENT/topf.yaml`. It never selects every node by default. Tab completion lists the hosts.
- Run `mise run //talos:apply --dry-run <node>...` for the same nodes before every apply. The dry run only shows the diff of each node. If the configuration of a node will change, it exits with code 2. topf redacts the Talos secrets in each diff, but not the NetBird setup key. If a diff changes the netbird patch, for example during a key rotation, the keys show in it. Do not share such a diff. A rotation replaces the key in Terraform, which deletes the old key in NetBird, so the old key no longer works.
- `//talos:apply` changes one node at a time. topf shows the diff of each node and asks before it applies the change. It applies with `auto` and waits until the node is ready again before it continues.
- Talos 1.14 applies most changes without a reboot, and it no longer reports whether a change needs one. If a change needs a reboot, the nodes reboot one at a time.
- If a change needs a reboot, apply it to the elected NetBird routing peer last, in a run of its own. A reboot of that peer drops the vRack route until NetBird elects another peer.
- Apply each change to staging first.
- An apply cannot destroy a server. The OVH control-plane instances and the bare-metal workers carry `prevent_destroy`. If a plan replaces or deletes one of them, the plan fails. To tear one down, remove that lifecycle rule in the same change.

## Rebuild an environment with a new secrets bundle

This procedure rebuilds the cluster of an environment with a new Talos secrets bundle, for example after the bundle leaks. The OVH infrastructure, the NetBird setup keys and the Infisical secrets stay as they are.

> [!CAUTION]
> Do not run this procedure on production unless you must rebuild it. It deletes all data in the cluster: the metrics, logs and traces, and the Grafana and GlitchTip databases. Reset the nodes only with the commands in step 1. Without `--system-labels-to-wipe`, a reset wipes the whole system disk, and the node then cannot boot Talos.

Run the commands from the root of the repository, with `ENVIRONMENT` set to the environment:

1. Reset every node while the current talosconfig still works, because the old bundle signs it. The commands below reset the workers first, then the control planes. They wipe only the system volumes, and on the workers also the user volumes that `talos/$ENVIRONMENT/topf.yaml` lists.

   ```bash
   topf="talos/$ENVIRONMENT/topf.yaml"
   for ip in $(yq -r '.nodes[] | select(.role == "worker") | .ip' "$topf"); do
     talosctl --endpoints "$ip" --nodes "$ip" reset --graceful=false --reboot \
       --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --system-labels-to-wipe u-hostpath \
       $(yq -r '.data.workerDataVolumes[] | "--system-labels-to-wipe u-" + .' "$topf")
   done
   for ip in $(yq -r '.nodes[] | select(.role == "control-plane") | .ip' "$topf"); do
     talosctl --endpoints "$ip" --nodes "$ip" reset --graceful=false --reboot \
       --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL
   done
   ```

   The installed Talos stays. Each node reboots into maintenance mode, because its configuration is gone.

2. Delete the old bundle. Step 1 reset every node, so the old bundle no longer opens anything, and you do not need a copy of it. In step 3, topf finds no bundle and asks whether to generate one. Answer yes, and `talos/bin/talos-secrets` stores the new bundle in Infisical.

   ```bash
   mise exec -- infisical secrets delete TALOS_SECRETS --type shared --env staging --path /talos
   ```

   In production, use `--env prod`. `mise exec` sets the Infisical instance and the `observability` project.

3. Configure the nodes and bootstrap the cluster: run step 8 of [Apply order](#apply-order). The bootstrap writes a new talosconfig and kubeconfig from the new bundle.
4. When Grafana is up in production, the grafana-operator creates the `rootly` service account and a new token, and a PushSecret writes the token to Infisical. Install that token in Rootly, as [Alerting](06-dashboards-and-alerts-guide.md#alerting) describes. The old token was in the old Grafana database.
5. When GlitchTip is up, repeat the sign-in setup in [GlitchTip](04-application-architecture-guide.md#glitchtip). GlitchTip keeps its Zitadel provider in its database, which the rebuild deletes.
6. In the NetBird dashboard, delete the old peers of the nodes. The Talos setup key is not ephemeral, so each node joins as a new peer, and its old peer stays.

## Tooling

OpenTofu and Terragrunt manage the infrastructure as code. topf renders the Talos machine configurations. helmfile installs the releases that Flux needs before it starts. mise sets the tool versions and runs the tasks. The version pins live in `.mise/config.toml` and in the lock file of each module.

When a command runs, the Infisical CLI (`infisical run`) injects the API credentials and the state bucket keys. `terraform/root.hcl` maps them to the module inputs and the S3 backend.
