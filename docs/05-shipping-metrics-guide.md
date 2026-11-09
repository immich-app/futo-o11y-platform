# Shipping metrics to the central store

This cluster is the central VictoriaMetrics store for all FUTO clusters. A remote cluster does not push into a special API. It runs its own `vmagent`, which sends data in the standard Prometheus remote-write format to an ingestion gateway on this cluster. This guide describes the two network paths into the store, the configuration that each path needs, and how to make sure that data arrives.

Each path ends at a `vmauth` gateway, and both gateways forward requests to the same `vminsert` tier. So the ingestion API, the label rules and the stored data are the same on both paths. The paths differ only in the hostname, the transport, and whether the gateway requires a token.

## The two paths

|                  | Over the NetBird mesh                     | Over the internet                     |
| ---------------- | ----------------------------------------- | ------------------------------------- |
| Gateway hostname | `vmauth.<mesh-domain>`                    | `vmauth.<app-domain>`                 |
| Envoy gateway    | `mesh` (mesh-only VIP)                    | `envoy` (public, via OVH IPLB)        |
| Auth             | none: the NetBird ACL is the gate         | shared bearer token                   |
| Transport        | private overlay, never leaves the mesh    | public internet, TLS at Envoy         |
| Use when         | the remote cluster is already a mesh peer | the remote cluster is not on the mesh |

> [!TIP]
> If a cluster is already joined to the FUTO NetBird mesh, prefer the mesh path. That path has no token to distribute or rotate, and its traffic never crosses the public internet.

If a cluster is not on the mesh, use the internet path. You can use both paths at the same time. They write to the same store.

### Per-environment endpoints

|                | staging                            | production                 |
| -------------- | ---------------------------------- | -------------------------- |
| Mesh gateway   | `vmauth.staging.o11y.futo.network` | `vmauth.o11y.futo.network` |
| Public gateway | `vmauth.staging.futostatus.com`    | `vmauth.futostatus.com`    |

The shared 1Password vault of each environment (`shared_tf_staging` / `shared_tf_prod`) also holds both gateway URLs, next to the bearer token. So a consuming cluster can read its endpoint from the vault and does not have to hardcode the hostname:

| Item                                     | Value (field `password`)       |
| ---------------------------------------- | ------------------------------ |
| `O11Y_VICTORIAMETRICS_VMAUTH_MESH_URL`   | `https://vmauth.<mesh-domain>` |
| `O11Y_VICTORIAMETRICS_VMAUTH_PUBLIC_URL` | `https://vmauth.<app-domain>`  |

Each item holds the bare origin: the scheme and the host, with no path. Append the insert path or the select path for your shipper. The Terraform module `deployment/modules/victoria-metrics/cluster` manages these items. Terraform also generates the token item, in the `shared-generated-secrets` module of core-infra-tf (`deployment/modules/shared/1password/futo-account/shared-secrets.tf`). That module makes a separate random value in each of `shared_tf_prod`, `shared_tf_staging` and `shared_tf_dev`.

The metrics remote-write path is the same on every host:

```text
/insert/0/prometheus/api/v1/write
```

The `0` in the path is only a placeholder. The central `vmauth` rewrites the path to the multitenant insert endpoint. Then the store assigns the real tenant from the `project` and `cluster` labels, as [Tenants](#tenants) describes.

## Prerequisites (both paths)

Both paths need a `vmagent` with a persistent disk buffer. The central store is a single point of failure for observability. With a disk buffer on each remote, a central outage does not drop data. When the store recovers, the buffered data replays. Give `vmagent` a PVC. Then set `-remoteWrite.tmpDataPath` to the mount path of that PVC. If the remote runs Prometheus, use its WAL and tune `queue_config` instead.

Both paths also need the mandatory identity labels. See [Labels](#labels).

## Option A: over the NetBird mesh

The remote cluster must be a NetBird peer, and a NetBird ACL must permit its group to reach the mesh gateway of this cluster. Its `vmagent` must send its traffic out through a mesh interface. It must also resolve `vmauth.<mesh-domain>` through mesh DNS. The NetBird section of the [infrastructure guide](02-infrastructure-architecture-guide.md) describes how peers and ACLs are modeled. On this cluster, the reference pattern is how `external-secrets` reaches the bootstrap 1Password Connect: a Multus egress interface plus mesh DNS.

This path needs no token, because the mesh ACL is the only gate. The gateway still terminates TLS with a publicly trusted `*.<mesh-domain>` certificate. So `https://` works without a custom CA.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAgent
metadata:
  name: central-forwarder
spec:
  externalLabels:
    project: yucca
    env: prod
    cluster: father # unique per remote, mandatory
    provider: hetzner
    region: fsn
  remoteWrite:
    - url: https://vmauth.o11y.futo.network/insert/0/prometheus/api/v1/write
  extraArgs:
    remoteWrite.tmpDataPath: /vmagent-buffer
  # ...plus a PVC mounted at /vmagent-buffer for the disk buffer
```

## Option B: over the internet

The public gateway rejects anonymous requests, so this path requires a shared bearer token. The token is in 1Password as the item `O11Y_VICTORIAMETRICS_VMAUTH_PASSWORD` (field `password`). It is in the same vault as the gateway URL items above.

A cluster that can read the vault pulls the token with an ExternalSecret. As an alternative, it injects the token from Terraform with an `op://shared_tf_<env>/O11Y_VICTORIAMETRICS_VMAUTH_PASSWORD/password` reference. That reference must match the gateway that the cluster ships to: `shared_tf_prod` for production, as yucca and bootstrap do. Do not make a copy of the token by hand. A hand-made copy goes stale at the next rotation.

To rotate the token, replace the `random_password` of that environment in core-infra-tf. Then apply the change in core-infra-tf. A hand edit to the vault item does not last, because the next apply of that module reverts it.

This gateway reads the new value through its own ExternalSecret. Consumers that use an ExternalSecret also read the new value. A consumer that copied the token at apply time keeps sending the old token until its own next apply. Until then, the gateway rejects it. An example is the `vmagent-remote-write` Secret of bootstrap, which Terraform injects.

```yaml
apiVersion: operator.victoriametrics.com/v1beta1
kind: VMAgent
metadata:
  name: central-forwarder
spec:
  externalLabels:
    project: yucca
    env: prod
    cluster: father # unique per remote, mandatory
    provider: hetzner
    region: fsn
  remoteWrite:
    - url: https://vmauth.futostatus.com/insert/0/prometheus/api/v1/write
      bearerTokenSecret:
        name: o11y-remote-write-token # a Secret holding the vault token
        key: token
  extraArgs:
    remoteWrite.tmpDataPath: /vmagent-buffer
  # ...plus a PVC mounted at /vmagent-buffer for the disk buffer
```

If the remote runs Prometheus and not `vmagent`, use this equivalent configuration:

```yaml
global:
  external_labels:
    project: yucca
    env: prod
    cluster: father
    provider: hetzner
    region: fsn
remote_write:
  - url: https://vmauth.futostatus.com/insert/0/prometheus/api/v1/write
    authorization:
      type: Bearer
      credentials_file: /etc/o11y/token
```

## Labels

Labels tell the data apart. One organization with mutual trust owns all the data, so all of it stays queryable together. The store puts the metrics of each cluster in a tenant of its own, which it assigns from these labels (see [Tenants](#tenants)). Logs stay in one tenant. Every shipper, for metrics and for logs, must stamp the same five identity labels on all data that it sends:

- `project`: the project that the cluster belongs to (for example `o11y` or `yucca`).
- `env`: the short environment name, which is `dev`, `staging` or `prod` (not `production`).
- `cluster` (mandatory, unique): a short name that is unique to the cluster (for example `father` or `o11y`). It keeps the series of one cluster from colliding with the series of another. It also lets alerting tell clusters apart. The o11y alert rules aggregate `by (cluster)`, and notifications group on it. If the `cluster` label is missing or reused, all clusters collapse into a single alert and a single notification. The label is easy to enforce now and difficult to add later.
- `provider`: the infrastructure provider (for example `ovh` or `hetzner`).
- `region`: the IATA or ICAO airport code nearest to the site (for example `fsn` or `aus`). A cluster that spans several sites uses `global`. The o11y clusters use `global`, because their nodes span three OVH datacenters.

The value sets are open. These values are conventions, not a closed list. For a given cluster, its own shipper configuration is the authority. The o11y clusters stamp `project=o11y, env=<staging|prod>, cluster=o11y, provider=ovh, region=global`. Each environment supplies `cluster` and `env` from `CLUSTER_NAME`/`CLUSTER_ENV` in `kubernetes/clusters/<env>/cluster-settings.yaml`.

`externalLabels` tags only scraped series. If the shipper also forwards pushed data, apply the same labels with a relabel configuration instead. An example of pushed data is OTLP app metrics through a `vmagent`. The relabel configuration tags the ingested series too.

### Make the identity labels win

The shipper adds external labels only to series that do not already have the label. Under `honor_labels`, a scraped label always wins. Some exporters emit their own `cluster` label. CloudNativePG stamps the name of its Cluster CR. The ServiceMonitors that Rook generates set `honor_labels` plus `cluster=<CephCluster namespace>`.

Those series reach the store with the value of the exporter, not your value. Then they are missing from your dashboards and alerts. They also land in tenant 0, because the registry does not know that cluster. The store cannot repair this, because the real value is gone before the sample arrives.

Fix this in the remote-write relabeling of the shipper, which sees scraped and pushed data alike. First, keep the value of each exporter under a dedicated label. Then set `cluster` unconditionally. The cluster azad ships these rules in its `VMAgent` (immich-app/futo-internal-platform#89):

```yaml
spec:
  inlineRelabelConfig:
    - if: '{job=~"rook-ceph-(mgr|exporter)"}'
      sourceLabels: [cluster]
      targetLabel: ceph_cluster
    - if: '{__name__=~"cnpg_.*"}'
      sourceLabels: [exported_cluster]
      targetLabel: pg_cluster
    - if: '{__name__=~"cnpg_.*"}'
      action: labeldrop
      regex: exported_cluster
    - targetLabel: cluster
      replacement: azad
```

The value from Rook stays as `ceph_cluster`. The scrape already moved the value from CNPG to `exported_cluster`, and the rules rename it to `pg_cluster`. The CNPG series of harbor use the same name, so one CNPG dashboard serves both. The last rule is the identity override. On the `/metric-relabel-debug` page of vmagent, you can paste sample series and see the result before you ship it.

If you use Prometheus, set `cluster` as a target label in `relabel_configs` for every scrape job. This gives the same result. With the default `honor_labels: false`, Prometheus renames a conflicting scraped label to `exported_cluster` automatically. A `metric_relabel_configs` rule can then move it under a dedicated name, as above.

### Shippers that push instead of scrape

The fleet-wide `o11y cluster stopped reporting` alert fires about 20 minutes after a tenant stops writing. It applies only to tenants that ingested within the last 7 days. The 20 minutes are a 15-minute window, then `for: 5m`.

A pusher such as a serverless worker often ships in bursts, and that window will misread the bursts as an outage. So the rule leaves out bursty tenants, and these tenants can go dark without anyone noticing. Today, those are the tenant of fmeet, and the geocoder and tiles tenants of geoshenanigans.

If a shipper pushes in bursts, emit one steady heartbeat metric from it. Add an `absent_over_time` alert on that metric in the project folder of the shipper. Match the window of that alert to the push cadence of the shipper. The serverless path below does not change this. That path writes only while events arrive and for 5 minutes after. So a worker with no traffic for 20 minutes looks down.

### Shippers that send one sample per event

A serverless worker (for example a Cloudflare Worker or a Lambda) cannot keep a counter between requests. Every invocation starts fresh, many run at the same time, and none lives longer than its request. What the worker can send is one sample per event. That sample is 1 for a request, or the value of the event itself, such as a row count.

If the worker sends these samples to `/insert/0/`, they collapse. The store keeps one sample per series per 20s (see [Sample cadence](#sample-cadence)). So 50 requests with the same labels in 20 seconds are stored as one sample.

Such shippers push to the serverless path instead. It is on the same gateways, with the same auth as the other paths (none on the mesh, the shared token on the internet):

|        | staging                                                       | production                                            |
| ------ | ------------------------------------------------------------- | ----------------------------------------------------- |
| Mesh   | `https://vmauth.staging.o11y.futo.network/serverless/insert/` | `https://vmauth.o11y.futo.network/serverless/insert/` |
| Public | `https://vmauth.staging.futostatus.com/serverless/insert/`    | `https://vmauth.futostatus.com/serverless/insert/`    |

The gateways route three endpoints. Each goes to the matching endpoint of `vmagent-serverless` (`kubernetes/apps/base/victoria-metrics-users/app/vmagent-serverless.yaml`), with `/serverless/insert` stripped:

- `.../serverless/insert/influx/write` for InfluxDB line protocol
- `.../serverless/insert/api/v1/import/prometheus` for Prometheus text
- `.../serverless/insert/api/v1/write` for remote write

Every minute, the aggregator (`vmagent-serverless`) writes a sum for each series as `<name>:1m_sum_samples`. The sum adds up the samples that arrived in that minute. For a series of 1s, it is the number of events. For a series of values, it is the total. The aggregator keeps every input label and adds `aggregator`, the name and UID of the pod that made the sum.

Each of the two replicas sums only the requests that the gateway sent to it. So a query must always add up over `aggregator`. Read the sums with `sum_over_time()`, which adds up the minutes in its window:

```promql
sum by (status) (sum_over_time(tiles_response_count:1m_sum_samples[5m]))
```

For a distribution, such as request durations, the shipper also sends a 1 per event in a `<name>_bucket` series. That series has a `vmrange` label with the bucket of the event. A `vmrange` bucket is a VictoriaMetrics histogram bucket, written as `"<lower>...<upper>"`. The lower bound is exclusive and the upper bound is inclusive. There are 18 buckets to a decade (`10^(k/18)...10^((k+1)/18)`). The shipper writes the bounds the way VictoriaMetrics writes them, for example `2.783e+01...3.162e+01`. The bucket sums then give quantiles:

```promql
histogram_quantile(0.99, sum by (vmrange) (sum_over_time(tiles_handle_request_duration_bucket:1m_sum_samples[5m])))
```

A shipper on this path must follow these rules:

- Stamp the five identity labels on every sample, as for `/insert/0/`. The shared token trusts the labels in the same way on this path.
- Add the rule pair of the shipper to the [tenant registry](#tenants), as for `/insert/0/`.
- Send no timestamps. The aggregator files a sample under the minute in which it arrives.
- Send no `aggregator` label. The aggregator sums by the labels that it receives, then overwrites `aggregator` with its own value. Two series that differ only in that label become one series, and the store keeps only one of the two sums.
- Send each event once, to one gateway. A sum cannot tell a resent sample from a new event. A sample sent to both gateways counts twice. If the first attempt of a push reached the aggregator but lost its response, a retry also counts twice.
- Keep label values bounded. Every label combination is a series. The aggregator writes that series every minute while it has events, and as zeros for 5 minutes after. For a distribution, each combination is one series per bucket. Put per-request values (client IPs, origins, user agents, error messages) in logs, not in labels. Some labels come from a request, for example a path segment or a query parameter. Limit the values of such a label to the ones that the shipper serves.
- Send gauges and heartbeats to `/insert/0/`, at most one sample per series per 20s. The serverless path will add up two readings of a gauge.

The aggregator keeps the minute in progress in memory. If a replica stops abruptly, it loses the events of that minute. If a replica stops within its first two minutes, it loses everything that it received. The reason is that its first flush comes at the end of the first whole minute after it started.

The sums of a finished minute also wait in memory for a few seconds. Then vmagent sends them or queues them on disk. So an abrupt stop immediately after a flush can lose that minute too. A clean shutdown first writes out the minute in progress. Beyond these cases, nothing is lost silently. There are no running totals, so a restart has no reset to hide.

## Sample cadence

The store deduplicates at 20s. `vmselect` runs `-dedup.minScrapeInterval=20s`. On read, this flag keeps the sample with the largest timestamp in each discrete 20s window and discards the rest. `vmstorage` applies the same interval during its background merges. So a query never sees more than one sample per 20s per series, however fast the samples arrived.

Anything sent faster costs mesh bandwidth, `vminsert` CPU and two copies on disk (the cluster runs `replicationFactor: 2`). Nobody can read that extra data back. The merge reclaims only the disk part, and only after the data already crossed the network.

Scrape at 20s or slower. Deduplicate all pushed data. The usual offender is an OTLP exporter with cumulative temporality. It re-sends an identical point for an unchanged instrument at every interval. So a 1s export interval from 75k instruments makes 75k samples/sec, and the store keeps one in twenty. Raise the interval of the exporter to 10s or more. Then collapse the remaining repeats in the remote write of the shipper:

```yaml
spec:
  remoteWrite:
    - url: https://vmauth.futostatus.com/insert/0/prometheus/api/v1/write
      streamAggrConfig:
        dedupInterval: 20s
```

`dedupInterval` keeps only the last sample per series per interval. The shipper applies it after relabeling and before it sends the block. So it drops repeats, not the shape of the data. A series that really moves still arrives with its latest value. Set it to 20s, the same as the store, and not to a shorter interval. With a shorter interval, aggregation results computed in the shipper disagree with the same query run against the store. On the shipper, `vm_streamaggr_dedup_dropped_samples_total` counts the samples that it removed.

To find the cadence of a cluster, divide the series that it holds by the rows that it sends. The send rate comes from the `vmagent` of the cluster:

```promql
sum(rate(vmagent_remotewrite_block_size_rows_sum{cluster="father"}[10m]))
```

The series count comes from `totalSeries` for the tenant of the cluster, in `/select/<tenant>/prometheus/api/v1/status/tsdb`. If the result is under 20s, the cluster ships samples that the store will throw away.

## Tenants

The store also keys metrics by VictoriaMetrics tenant (`accountID:projectID`). `accountID` is usually the project, and `projectID` is the cluster in that project. geoshenanigans is the exception: it shares accountID 6 with immich. Shippers never see tenant IDs. A shipper writes to the `/insert/0/...` URL with the shared token, as shown above. The central `vmauth` rewrites that URL to the multitenant insert endpoint.

Then `vminsert` assigns the tenant from the `project` and `cluster` labels. It uses the relabel rules in `kubernetes/apps/base/victoria-metrics/app/configmap-vminsert-relabel.yaml`, which is the tenant registry. A cluster with no rule lands in tenant 0.

IDs are unique within a store. An environment pair is a prod cluster and its staging twin, each of which ships to its own store. Both clusters of a pair share the same tenant, so tenant-scoped configuration carries across environments unchanged. A cluster with no twin takes the next free number in its project. `accountID` 0 and `projectID` 0 are never assigned. Any cluster without a rule pair lands in `0:0`, whatever its project.

Rules are keyed on `project;cluster` for both labels, never on the project alone. So each cluster gets its own rule, and a new cluster in a known project stays in tenant 0 until it has one. The table below records the assignments. The rule pair in the ConfigMap, and nothing else, puts a cluster live on its tenant. So add the table row and the rule in the same change.

| Project        | accountID | Cluster              | Env           | Store      | Tenant |
| -------------- | --------- | -------------------- | ------------- | ---------- | ------ |
| o11y           | 1         | o11y                 | staging, prod | both       | `1:1`  |
| yucca          | 2         | father               | prod          | production | `2:1`  |
| yucca          | 2         | netops               | prod          | production | `2:2`  |
| yucca          | 2         | spice                | prod          | production | `2:3`  |
| yucca          | 2         | luke                 | staging       | staging    | `2:4`  |
| harbor         | 3         | harbor-infra-prod    | prod          | production | `3:1`  |
| harbor         | 3         | harbor-infra-staging | staging       | staging    | `3:1`  |
| fip            | 4         | azad                 | prod          | production | `4:1`  |
| fmeet          | 5         | serverless           | staging, prod | both       | `5:1`  |
| immich         | 6         | pokedex              | prod          | production | `6:1`  |
| version        | 7         | version              | dev, prod     | both       | `7:1`  |
| bootstrap      | 8         | palpatine            | prod          | production | `8:1`  |
| geoshenanigans | 6         | geocoder             | prod          | production | `6:2`  |
| geoshenanigans | 6         | tiles                | dev, prod     | both       | `6:3`  |
| fap            | 9         | fap-us-east-1        | prod          | production | `9:1`  |
| fap            | 9         | fap-us-west-1        | prod          | production | `9:2`  |

Onboarding a cluster onto its own tenant needs a change on the central side only. Add the rule pair of the cluster to the tenant registry. For example:

```yaml
- source_labels: [project, cluster]
  regex: yucca;father
  target_label: vm_account_id
  replacement: "2"
- source_labels: [project, cluster]
  regex: yucca;father
  target_label: vm_project_id
  replacement: "1"
```

`vminsert` reloads the file without a restart. No backfill is necessary. The older history of the cluster stays in tenant 0 and ages out with retention. Until then, the Fleet datasource reads it together with the new tenant.

The o11y rules also match samples with `project=o11y` and no `cluster` label. The `vmalert` of the o11y cluster writes such samples. The IDs of the o11y cluster come from `CLUSTER_VMETRICS_ACCOUNT_ID` and `CLUSTER_VMETRICS_PROJECT_ID` in `kubernetes/clusters/<env>/cluster-settings.yaml`. These values also drive the tenant-scoped reads of the o11y cluster: the default Grafana datasource, `vmalert` and the MCP server.

Fleet-wide reads use the `/select/multitenant/prometheus` endpoint. It spans every tenant, tenant 0 included. So cross-cluster dashboards and alerts also see the clusters in tenant 0. Logs stay in a single tenant, and only labels tell them apart.

## Make sure that data arrives

Query the series of the remote from the central side. Over the mesh, no token is necessary. The browsable UI is at `https://vmetrics.<mesh-domain>/select/multitenant/vmui/`. You can also query the API directly:

```bash
curl -s 'https://vmauth.o11y.futo.network/select/0/prometheus/api/v1/query' \
  --data-urlencode 'query=count(up{cluster="father"})'
```

Over the internet, send the same query with the shared bearer token from [Option B](#option-b-over-the-internet) in `$TOKEN`:

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  'https://vmauth.futostatus.com/select/0/prometheus/api/v1/query' \
  --data-urlencode 'query=count(up{cluster="father"})'
```

If the count is not zero, the series of the remote are landing. If the count is zero, look for send errors in the `vmagent_remotewrite_*` metrics of the remote `vmagent`. Also make sure that the remote sets the `cluster` label.

## Logs, on the same gateways

Logs use the same `vmauth` hostnames, because VictoriaLogs is behind the same gateways. Point a log shipper at `https://vmauth.<host>/insert/<format>/...`. Set `<format>` to one of `native`, `jsonline`, `opentelemetry`, `loki`, or `elasticsearch`. Read logs back with `/select/logsql/...`. Auth is the same as for metrics: none on the mesh, and the bearer token on the internet.

Logs carry the same identity labels as metrics. The shipper stamps them as fields. For example, the `victoria-logs-collector` chart takes them through `extraFields`.

### Shipping logs from an app

> [!CAUTION]
> Do not ship the shared token above inside an app binary, where any credential is public. The token is for clusters that we run, and it also grants `select`.

Instead, a client-side shipper gets its own write-only user on the public gateway. Today, that shipper is the Harbor mobile app. `kubernetes/apps/base/victoria-metrics-users/app/vmuser-client-logs.yaml` defines this user:

- Token: the 1Password item `O11Y_VICTORIALOGS_CLIENT_TOKEN`, in the same `shared_tf_<env>` vault as the gateway URLs. The `shared-generated-secrets` module of core-infra-tf generates it, with one value per environment. The token allows nothing but the two insert paths below.
- Paths: `https://vmauth.<app-domain>/client/harbor-mobile/insert/jsonline` for [JSON lines](https://docs.victoriametrics.com/victorialogs/data-ingestion/#json-stream-api), which need no SDK, and `.../client/harbor-mobile/insert/opentelemetry/v1/logs` for OTLP. `vmauth` strips the `/client/<name>/` prefix before the request reaches VictoriaLogs. The prefix lets the gateway rate limit these paths on their own. `httproute-client-logs.yaml` sets a local request limit per Envoy replica, answered with `429`. It also sets a 1 MiB cap per request, answered with `413`. OTLP is protobuf only. VictoriaLogs rejects a JSON-encoded OTLP body, so a hand-rolled client posts JSON lines.
- Identity fields: these are pinned on the server side as `project=harbor, cluster=harbor-mobile, env=<staging|prod>, provider=mobile, region=world`. The log stream is keyed on `project,cluster,env`. VictoriaLogs reads query args before `VL-*` headers, and the args of the gateway come first. So a client cannot relabel itself into another project or create a stream per device. The `AccountID`/`ProjectID` headers are forced to the single logs tenant. Anything else that the app sends (for example `platform`, `app_version` or `device_id`) is stored as a regular field and stays queryable.

Each JSON line is one log entry. `_msg` is the message, and `_time` is the timestamp (RFC 3339, or `"0"` for "now"). Send `Content-Type: application/stream+json`. The endpoint accepts a form-encoded body, but it silently ingests nothing from it. It rejects a pretty-printed body. Send one object per line only.

```sh
printf '%s\n' \
  '{"_time":"0","_msg":"sync finished","level":"info","platform":"ios","app_version":"1.4.2"}' \
  '{"_time":"0","_msg":"upload failed: timeout","level":"error","platform":"ios","app_version":"1.4.2"}' |
  curl -fsS -X POST -H "Authorization: Bearer $O11Y_VICTORIALOGS_CLIENT_TOKEN" \
    -H 'Content-Type: application/stream+json' --data-binary @- \
    'https://vmauth.staging.futostatus.com/client/harbor-mobile/insert/jsonline'
```

Batch the logs on the client: a few seconds or a few hundred lines per request, under 1 MiB. If the gateway answers `429`, `413` or `5xx`, back off. Drop logs rather than queue them forever.

The gateway limits are a brake against a leaked token, not a quota per app. A leaked token is still rotated: the 1Password item is regenerated, and the app is released again. Read the logs back as the [Tenants](#tenants) section describes, with a filter on `cluster:harbor-mobile`:

```sh
curl -fsS 'https://vlogs.<mesh-domain>/select/logsql/query' --data-urlencode 'query=cluster:harbor-mobile | limit 10'
```

A second client-side shipper gets its own `VMUser`, token item and `/client/<name>/` prefix on the same route. Nothing else changes.

## Traces, on the same gateways

Traces use the same `vmauth` hostnames under a `/traces/` prefix. The gateway strips that prefix before the request reaches VictoriaTraces. Point an OTLP/HTTP exporter at `https://vmauth.<host>/traces/insert/opentelemetry/v1/traces`. Read traces back under `/traces/select/...`. The Jaeger query API is at `/traces/select/jaeger/api/...`.

The prefix exists because OTLP logs and traces share `/insert/opentelemetry/`, and both gateways send that path to VictoriaLogs. The gateways do not route OTLP over gRPC. Auth is the same as for metrics and logs.

Stamp the five identity labels as resource attributes, for example with the `resource` processor of the OpenTelemetry Collector. VictoriaTraces keys streams on `service.name` and the span name. It keeps every other resource attribute and span attribute as a queryable field. To make sure that spans arrive, use the mesh to list the services that reported:

```sh
curl -fsS 'https://vtraces.<mesh-domain>/select/jaeger/api/services'
```

## What backs this centrally

Maintainers find the ingestion configuration in `kubernetes/apps/base/victoria-metrics-users/app/`:

- `vmuser-remote-clusters.yaml`: the `VMUser` behind the public gateway. It holds the shared token (through an ExternalSecret) and the allowed path set. That set has the insert paths and the select paths for metrics, logs and traces. So remote clusters can read back, not only write.
- `vmauth-mesh-unauth.yaml`: the unauthenticated `mesh-unauth` `VMAuth` on the mesh gateway. It exposes the same path set through `unauthorizedUserAccessSpec`.
- `vmagent-serverless.yaml`: the aggregating `vmagent` behind the three `/serverless/insert/` endpoints of both gateways. It has two stateful replicas with a disk queue. It scrapes nothing and writes the sum per minute of each series to `vminsert`.

The public gateway itself is the `vmauth` that the VictoriaMetrics release defines (`kubernetes/apps/base/victoria-metrics/app/helmrelease.yaml`). Its address is `vmauth.<CLUSTER_APP_DOMAIN>`.
