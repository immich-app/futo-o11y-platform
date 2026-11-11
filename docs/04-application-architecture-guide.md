# Application architecture guide

This guide describes the workloads that run on the cluster: the ingress edge, the observability stack, and the operators that support them. Flux manages all of them. Each workload lives in the `o11y` namespace, unless this guide names a different namespace.

## Ingress edge

### Envoy Gateway

Envoy Gateway is the only ingress from outside the cluster. The OVH load balancer (the IPLB) does TCP passthrough to the NodePort of Envoy, and TLS terminates at Envoy. Envoy runs one replica on each worker, with a topology-spread constraint on the hostname. Thus every IPLB backend has a local endpoint under `externalTrafficPolicy: Local`.

The IPLB prepends PROXY protocol v2. A client traffic policy tells Envoy to parse PROXY protocol v2 as optional. Thus Envoy does not reset the bare-TCP health probe of the IPLB, and real client connections still show the true source IP. Platform services (Grafana, vmauth, the echo test app) attach to the gateway through HTTPRoutes.

### Mesh gateway

A second Envoy Gateway (`mesh`, in `envoy-system`) serves NetBird peers, not the public internet. It sits behind a pinned VIP Service that the mesh advertises. The NetBird section of the infrastructure guide describes this Service.

For mesh-facing HTTPRoutes, the gateway terminates TLS with a `*.<mesh-domain>` wildcard certificate. The certificate comes from the same cert-manager pipeline as the public gateway. One of these routes is an unauthenticated vmauth at `vmauth.<mesh-domain>`. It gives other FUTO clusters a remote-write path that never leaves the mesh.

The gateway also has a TLS-passthrough listener on `:6443` in front of the kube-apiserver, as `kube.<mesh-domain>`. The listener routes by SNI to the `kubernetes` Service and load-balances across all three control planes. The apiserver presents its own certificate end to end.

### TLS certificates

cert-manager issues short-lived ECDSA P-256 wildcard certificates with always-rotate. It gets them from Let's Encrypt through the OVH DNS-01 challenge webhook. The base manifests define the certificate `dnsNames` once, with the `CLUSTER_APP_DOMAIN` placeholder. Each environment resolves the placeholder from `cluster-settings`. Staging gets `*.staging.futostatus.com`, and production gets the bare-domain wildcards.

## VictoriaMetrics: the central metrics store

The VictoriaMetrics on this cluster is the central metrics store for all FUTO clusters. Each other Kubernetes cluster runs its own `vmagent` and remote-writes into this cluster. This cluster is the ingestion target for all clusters. It also runs the queries and the alerting for all of them.

- Storage: VictoriaMetrics runs in VMCluster mode with `replicationFactor=2`. There is one `vmstorage` on each worker, across the three data centers (DCs), on `openebs-spare-disk`. `CLUSTER_VMETRICS_RETENTION` sets the retention for each environment (30d staging, 120d production). The `vmstorage`, `vminsert`, and `vmselect` tiers scale independently.
- Local collection: a `vmagent` with a persistent disk buffer scrapes this cluster. It remote-writes to the multitenant endpoint of the local `vminsert`. It tags the series with the identity of the cluster, and `vminsert` derives the tenant from that identity.
- Alerting: `vmalert` evaluates the rules. There is no Alertmanager yet, so the notifications go to a blackhole. The rules still evaluate, and the recording rules still write. If the bundle of a tenant ships `VMRule`s, that tenant gets its own `vmalert`. That instance reads only its tenant, and it writes back into the tenant through the identity labels of the tenant. o11y labels those rules `o11y.futo.org/tenant`, and the o11y `vmalert` skips them ([dashboards and alerts guide](06-dashboards-and-alerts-guide.md#recording-rules-in-a-bundle)).
- Ingestion gateway: a locked-down `vmauth` sits in front of `vminsert`. It allows no anonymous access and runs as an HA pair. It is public at `vmauth.<CLUSTER_APP_DOMAIN>`, through the Envoy Gateway and the IPLB, with TLS from cert-manager.

### Tenancy and auth

Each cluster lands in its own VictoriaMetrics tenant, with `accountID` = project and `projectID` = cluster. The registry of tenants is in the [shipping guide](05-shipping-metrics-guide.md#tenants). Every series also carries the mandatory identity labels. All clusters belong to one organization and trust each other. You can query all of them together through the multitenant read endpoint.

This cluster derives the tenant centrally, and the shippers do not declare it. A single shared bearer token authenticates all remote clusters. The `VMUser` that the token is bound to rewrites each write onto the multitenant insert endpoint. Then `vminsert` relabeling maps the `project`/`cluster` labels of each sample to a tenant. Remotes ship only the five identity labels. Per-tenant enforcement is possible later: move a remote to its own token, pinned to its tenant path.

Infisical stores the token, and an ExternalSecret injects it into that `VMUser`. The operator installs the `VMUser` CRD. Thus those resources live in a separate Flux Kustomization that depends on the VictoriaMetrics release and external-secrets. This order prevents a race with the CRD registration.

Serverless pushers can only send one sample per event. They write to `/serverless/insert/` on the same gateways instead. That path goes to `vmagent-serverless`, which writes the per-minute sum of each series to `vminsert`. Thus the 20s deduplication of the store does not drop events. For details, see the [shipping guide](05-shipping-metrics-guide.md#shippers-that-send-one-sample-per-event).

### Label convention

Every shipper stamps the same five identity labels: `project`, `env`, `cluster`, `provider`, `region`. This rule applies to metrics and to logs, and to remote and to local shippers. Each `cluster` value must be unique, so that series from different clusters do not collide. This rule is cheap to enforce now and expensive to add later. The [shipping guide](05-shipping-metrics-guide.md#labels) defines the values. This cluster gets its own pair of values from `CLUSTER_NAME`/`CLUSTER_ENV` in `cluster-settings`.

### Onboarding a remote cluster

To onboard a remote cluster, do these steps:

1. On the central cluster, add the remote cluster to the tenant registry. Until you add it, its data lands in tenant 0.
2. On the remote cluster, pull the shared token from the same vault item into a Secret.
3. Configure the `vmagent` of the remote cluster with these items:
   - A persistent disk buffer, so that a central outage does not lose data. When the central store recovers, the data replays.
   - The mandatory external labels.
   - A remote-write to the public `vmauth` endpoint, authenticated with the bearer token.

> [!WARNING]
> Do not edit the vault item of the token. core-infra-tf generates the token, so rotate it there.

After a rotation, re-apply each cluster that injects the token from Terraform. ExternalSecret consumers re-sync on their own. For details, see [Option B in the shipping guide](05-shipping-metrics-guide.md#option-b-over-the-internet).

If you ever need per-cluster revocation, split the setup into per-cluster vault items and `VMUser`s.

### Operating notes

The central store is a single point of failure for all observability. Three things reduce this risk:

- The disk buffer on each remote.
- The resilience from RF=2 across three DCs.
- Meta-monitoring (monitoring of the monitoring stack). It must live outside this cluster, because the cluster cannot watch itself.

The total load scales with the sum of the active series of all clusters. As clusters onboard, grow the storage tier and the insert and select tiers. Also add cardinality guardrails, so that one remote that misbehaves cannot overwhelm the store.

## VictoriaLogs

Logs run as a VLDistributed resource. The `vldistributed` block of the `victoria-metrics-k8s-stack` HelmRelease declares it. This is the same HelmRelease that runs the metrics tier. The VictoriaMetrics operator reconciles the resource. VictoriaLogs has no cross-node replication: `vlinsert` shards across `vlstorage`, and there is no `replicationFactor`. Thus durability comes from two independent zones, not from replication inside one cluster.

Each zone is a `VLCluster` with a single `vlstorage` of size `CLUSTER_VMLOGS_SIZE` on `CLUSTER_VMLOGS_STORAGE_CLASS`. `CLUSTER_VMLOGS_RETENTION` sets the retention for each environment (30d staging, 120d production). The manifests do not pin the VictoriaLogs release. Like the metrics components, it follows `global.versions` of the chart. Thus a k8s-stack bump upgrades the zones, one at a time (see below).

A hostname topology spread with `DoNotSchedule` on `app.kubernetes.io/name: vlstorage` keeps the storage of the two zones on different workers. The metrics tier uses the same idiom. This spread lets each zone survive independently. Both environments have only three workers, and the PVCs are node-local. If two zones share a node, they fail together.

The operator runs one `vlagent` per zone, and each agent replicates every log line to the `vlinsert` of every zone. The agents have an explicit 20Gi persistent queue. Without this configuration, the operator falls back to an `emptyDir`. With an `emptyDir`, an agent restart loses all data that is buffered for a zone that is down. That loss defeats the purpose of the agent. The operator divides the PVC across the destinations, so with two zones each destination gets 10Gi of buffer.

The agents have the same hostname spread as the storage, because their queue PVCs are node-local too. Also, the managed VMAuth routes every insert only to the agents. If two agents are pinned to one worker, the loss of that worker takes down the whole write path.

The operator puts a managed `VMAuth` named `victoria-logs` on port 8427 in front of the whole setup. Every log read and every log write goes through it. Thus it runs at two replicas with a disruption budget and a hostname spread, like the public metrics gateway. This one endpoint serves both directions: `/insert/*` is load-balanced across the zone agents, and `/select/*` is `first_available` across the zone selects. As a result, a degraded zone fails over.

All clients point at this endpoint:

- The `victoria-logs-collector` DaemonSet.
- The `talos-logs` DaemonSet, for node logs.
- The external clusters that arrive through the two vmauth gateways.
- The Grafana datasource.
- `victoria-logs-mcp`.
- The `vlogs.` mesh route.

The chart value `vldistributed.name` gives the CR the explicit name `victoria-logs`, so the CR does not inherit the `fullnameOverride` of the release. The operator names the managed VMAuth after the CR. If the CR has the name `victoria-metrics`, its VMAuth adopts and overwrites the public metrics gateway, which has the same name. The explicit name prevents this collision. It also makes each derived object (`victoria-logs-a`, `vlstorage-victoria-logs-a`) say what it is.

The `victoria-metrics` Flux Kustomization health-checks the CR through `healthCheckExprs` on `status.updateStatus`. Thus the consumers that depend on the Kustomization wait until the zones are operational, not only until the CR is accepted.

The operator upgrades one zone at a time. For each zone, it drains the agent queue, removes the zone from the VMAuth read and write targets, and reconciles the zone. Then it waits for readiness, restores the zone, and pauses before the next zone. `search.allowPartialResponse` stays unset on purpose. A partial response is a 200 with incomplete data and no error, and vmauth fails over only on an error status.

A read-only legacy tier also runs. It uses the `victoria-logs-cluster` chart, with three `vlstorage` shards, in `kubernetes/apps/base/victoria-logs/`. Its `vlinsert` is disabled, so nothing can write to it. The only access is through the `VictoriaLogs Legacy` Grafana datasource (uid `VictoriaLogsLegacy`).

The legacy tier holds the logs from before the two zones existed. It keeps them until they age out under its own retention. The default `VictoriaLogs` datasource, `victoria-logs-mcp`, the `vlogs.` mesh route and both gateways see only the two zones.

Logs stay single-tenant (tenant 0). The five labels (`project`/`env`/`cluster`/`provider`/`region`) identify them, and the logs carry these labels as fields.

VictoriaLogs has tenants too: an `(AccountID, ProjectID)` pair, like VictoriaMetrics. But request headers set the tenant, not URL path segments. Also, VictoriaLogs has no cross-tenant read: only `/insert/multitenant/native` exists, with no select equivalent. A split of the logs across tenants makes fleet-wide queries impossible. [VictoriaLogs#91](https://github.com/VictoriaMetrics/VictoriaLogs/issues/91) tracks this upstream. If it ships, revisit the single-tenant choice.

### Remove the legacy tier

When the legacy tier is empty, remove it. If the tier is empty, this query returns no rows:

```fish
kubectl get --raw '/api/v1/namespaces/o11y/services/victoria-logs-vlselect:9471/proxy/select/logsql/query?query=*%20%7C%20limit%201&allow_partial_response=0'
```

The query does not accept a partial response, because the legacy `vlselect` allows one by default. If the query returns an error, a shard is down. Fix the shard before you continue, because the error does not show that the tier is empty.

> [!WARNING]
> Before you remove the legacy datasource, search the dashboard JSON for `VictoriaLogsLegacy`. If a dashboard uses this uid, it breaks without the datasource.

Remove these in one PR:

1. `kubernetes/apps/base/victoria-logs/`, and its entry in `kubernetes/apps/<env>/o11y/kustomization.yaml` for both environments.
2. `kubernetes/apps/production/o11y/patches/victoria-logs.yaml`, and its `patches:` line.
3. `kubernetes/apps/base/grafana/app/datasource-victoria-logs-legacy.yaml`, and its `kustomization.yaml` line.

After Flux prunes the HelmRelease and its pods, delete the PVCs `vlstorage-volume-victoria-logs-vlstorage-{0,1,2}` in the `o11y` namespace by hand. Flux does not delete them.

## VictoriaTraces

Traces use the same two-zone layout as logs. The operator has no `VTDistributed`, so the layout is built by hand in `kubernetes/apps/base/victoria-traces/`. VictoriaTraces does not replicate between `vtstorage` nodes either, so each zone holds a full copy. The zones are the `VTCluster` resources `victoria-traces-a` and `-b`. Each zone has one `vtstorage` of size `CLUSTER_VTRACES_SIZE` on `CLUSTER_VTRACES_STORAGE_CLASS`, with retention `CLUSTER_VTRACES_RETENTION` (14d staging, 30d production). The same hostname spread as the log zones keeps the zones on different workers.

The `vtselect` and `vtinsert` of each zone are pinned to the storage worker of that zone. Thus the loss of one worker takes out at most one zone. If a select is not pinned, it can share a worker with the storage of the other zone. Then the loss of that worker takes down both read paths at once.

When its data passes `CLUSTER_VTRACES_SIZE` (`-retention.maxDiskSpaceUsageBytes`), each `vtstorage` also drops its oldest days. It does this because local-hostpath does not enforce PVC sizes, and metrics and logs share the disk. The limit is a retention threshold, not a hard cap. The last two days always stay, so a burst can still exceed it.

As in the upstream cluster guide, `vtinsert` runs with `-select.disable` and `vtselect` runs with `-insert.disable`. The `o11y traces spans dropped` Grafana alert carries the `vt_rows_dropped_total` rule that upstream recommends.

Each zone has one `VTAgent`, which writes every span to the `vtinsert` of both zones (`/insert/native`). Each agent has a 20Gi queue PVC, and the operator splits it per destination. A `VMAuth` named `victoria-traces` on port 8427 is the one endpoint. It uses the same url_map that VLDistributed generates for logs. `/insert/*` is load-balanced across the agents, and `/select/*` is `first_available` across the zone selects.

The gateways reach the endpoint under `/traces/`. They strip this prefix before they forward the request, because OTLP logs already own `/insert/opentelemetry/`. Grafana reaches it through the `VictoriaTraces` Jaeger datasource, and people reach it through the `vtraces.` mesh route. The k8s-stack release contributes only the upstream dashboard and rules. They are enabled explicitly, because the chart ties them to its own single `vtcluster`.

The hand-built version does not have the upgrade orchestration of VLDistributed. The zones follow `global.versions.traces` of the chart. A version bump rolls both zones at once, and it does not drain and update one zone at a time. During the roll, writes wait in the agent queues, but reads can fail while both zones restart.

The agents need the `/insert/native` path of `vtinsert`, which VictoriaTraces v0.11.0 added. Thus neither environment can run a k8s-stack older than 0.97.0, the first version that ships a v0.11.0+ default.

## Grafana

Grafana runs as a 3-replica HA deployment that the Grafana operator manages. Rolling updates do not block (zero surge, one unavailable). A topology-spread constraint puts one replica on each worker.

Pod storage is ephemeral, and all state lives in Postgres. The replicas share a single security secret key from Infisical, so signed cookies and sessions are valid on any replica. Grafana connects to its Postgres over TLS. The password comes from an environment variable and is not written into the configuration.

Users reach Grafana at `grafana.<CLUSTER_APP_DOMAIN>` and at the alternate domain.

## GlitchTip

GlitchTip is the error tracker. Apps send exceptions with the regular Sentry SDKs, pointed at a GlitchTip DSN, and GlitchTip groups them into issues. It runs from the upstream chart in `kubernetes/apps/base/glitchtip/`. GlitchTip publishes the chart only to the GitLab Helm registry, so the cluster pulls it from the home-operations OCI mirror. GlitchTip is public at `glitchtip.<CLUSTER_APP_DOMAIN>`, because browser and mobile SDKs post to it directly. Two replicas each run the web server and the task worker in one process.

The database is the `glitchtip-postgres` CloudNativePG cluster (`kubernetes/apps/base/glitchtip-postgres/`). CloudNativePG `Database` and `DatabaseRole` resources declare its database and owner role. The owner password is generated in-cluster into `glitchtip-postgres-credentials`, and its `uri` is the `DATABASE_URL` of GlitchTip. There is only one role. GlitchTip runs migrations and maintains partitions as the same role that it serves with. Also, neither resource can grant table privileges to a second role.

The cache, the sessions and the task queue live in a Dragonfly (`glitchtip-dragonfly`), not in the Valkey of the chart. The `dragonfly-operator` in `dragonfly-system` runs this Dragonfly. Ingest accepts an event as soon as the event is in the queue. If both Dragonfly replicas are lost, the events queued since the last 15-minute snapshot are lost too.

Uploads, for example sourcemaps, go to the OVH bucket for each environment, named in `CLUSTER_GLITCHTIP_S3_BUCKET`. `deployment/modules/glitchtip/cluster` creates the bucket with the same user split as the backup buckets. A keyless owner user owns the bucket. GlitchTip writes as a second user, whose S3 policy reaches only this bucket. The split is there because an owner ignores its policy, and the project also holds the backups. The module writes the keys of the writer user to `GLITCHTIP_S3_ACCESS_KEY_ID` / `GLITCHTIP_S3_SECRET_ACCESS_KEY` in `o11y_tf_<env>`.

GlitchTip keeps its own `/metrics` off, because the endpoint has no authentication on the public route.

Sign-in is through Zitadel only. The project role check in Zitadel decides who can log in. The project is `GlitchTip O11y` in core-infra-tf. The first Zitadel login creates the GlitchTip user. GlitchTip has no switch to enforce Zitadel-only sign-in: it allows a signup while no user exists, and it keeps password and passkey login.

Thus the public route answers requests for these parts with a 404:

- The Django admin.
- The local-account endpoints of the allauth API of GlitchTip.
- The per-organization SSO API of GlitchTip. Through this API, an organization manager can add an identity provider that bypasses Zitadel.

The full app, with the admin, is reachable only on the mesh at `glitchtip.<mesh-domain>`.

GlitchTip keeps OIDC providers in its database. Thus you configure the provider there, once for each environment:

1. Create a superuser with `kubectl -n o11y exec -it deploy/glitchtip-web -- ./manage.py createsuperuser`.
2. Sign in at `https://glitchtip.<mesh-domain>/admin/`.
3. Under Social applications, add an OpenID Connect app with these values:
   - Provider ID: `zitadel`. The `/accounts/oidc/zitadel/login/callback/` redirect that is registered in Zitadel uses this ID.
   - Name: `Zitadel`.
   - Client ID and secret: `FUTO_ZITADEL_OAUTH_CLIENT_ID_GLITCHTIP_O11Y` / `FUTO_ZITADEL_OAUTH_CLIENT_SECRET_GLITCHTIP_O11Y` in `shared_tf`.
   - Settings: `{"server_url": "https://auth.internal.futo.org/.well-known/openid-configuration"}`.

If email is not configured, you share organization invites as links.

## CloudNativePG

The database of Grafana is a CloudNativePG cluster. The operator runs in the `cnpg-system` namespace. The `grafana-postgres` cluster runs three instances on `openebs-system-disk`, with required pod anti-affinity (one per worker). Its credentials are basic-auth Secrets (a superuser and the Grafana owner) from Infisical. CloudNativePG requires that secret type, and the username of the database owner must match the secret.

## Supporting components

- external-secrets: syncs Infisical secrets into Kubernetes Secrets through two cluster secret stores, `infisical` (the `observability` project, this environment's `/tf`) and `infisical-shared` (the `shared` project). Both log in with the Universal Auth client credentials of the cluster's identity, which `mise run //bootstrap:resources` puts into the `external-secrets` namespace. The controller reaches Infisical on the bootstrap cluster (`infisical.futo.network`) over the NetBird mesh: the pod has a Multus egress interface and resolves the name through mesh DNS. Nearly every app above gets its credentials this way.
- Multus: a meta-CNI that gives pods opt-in secondary interfaces. The only attachment at this time is `netbird-egress`, which external-secrets and gatus use.
- gatus: the status page at `gatus.<mesh-domain>`. It probes the HTTPRoutes on both gateways, which its sidecar discovers. It also probes the 1Password Connect of every project on the bootstrap cluster (`opc.<project>.futo.network/heartbeat`). These probes are static and go over the `netbird-egress` leg. The results are scraped as `gatus_results_*`. The alert bundle of the bootstrap project pages on the Connect probes of production.
- grafana-operator: manages the Grafana instance, and also the dashboard and datasource resources. The VictoriaMetrics chart provisions these resources.
- prometheus-operator CRDs: the ServiceMonitor/PrometheusRule CRDs that the VM stack consumes.
- OpenEBS: the local-hostpath provisioner behind the `openebs-system-disk` and `openebs-spare-disk` StorageClasses, and on production also `openebs-spare-disk-2`.
- Spegel: a peer-to-peer image registry mirror across the nodes.
- descheduler: rebalances pods.
- reloader: reloads pods after a configuration change.
- metrics-server: serves the resource-metrics API.
