# Shared Grafana dashboards

This directory builds the cluster-generic dashboards. Each environment provides them once, in the `Shared` Grafana folder, so the tenant bundles do not ship them. Each dashboard reads the `VictoriaMetrics Fleet` datasource and filters on a multi-select `$cluster` variable. So one copy serves every cluster in the fleet.

## How it is built

`sync-job.yaml` is the configuration for the [VictoriaMetrics sync-job](https://github.com/VictoriaMetrics/helm-charts/tree/master/hack/sync-job). The VictoriaMetrics chart runs the same tool in the cluster. In generate mode, the sync-job does these steps for each upstream dashboard listed under `sources`:

1. It fetches the dashboard.
2. It renames the cluster label.
3. It adds a `cluster=~"$cluster"` filter to selectors and `by (cluster)` to aggregations.
4. It uses the variable whose `label_values()` query reads the `cluster` label as the cluster picker. If the dashboard has no such variable, it adds one from the `variables` override of the dashboard.
5. It points fixed datasource references at `VictoriaMetricsFleet`.
6. It writes `GrafanaDashboard` CRs into `manifests/dashboards.yaml`.

Then a `yq` step pins every datasource-type variable to the Fleet datasource. The sync-job does not pin these variables. No generated file goes into git: `manifests/dashboards.yaml` is git-ignored.

In CI, `.github/workflows/o11y.yaml` runs the same mise tasks. For a pull request, CI renders the bundle and runs `kustomize build` on it. For each push to `main` that changes `o11y/`, CI renders the bundle again. CI then publishes `manifests/` as the signed OCI artifact `ghcr.io/immich-app/futo-o11y-platform/o11y-manifests:main` (`flux push artifact` plus keyless cosign). The tenant bundles use the same shape and naming. Upstream changes reach the clusters on the next publish. To get them without a configuration change, run the workflow again by hand. The central cluster consumes the artifact and the `Shared` folder in `manifests/folder.yaml` through `kubernetes/apps/base/tenants/shared/bundle.yaml`.

```fish
mise run //o11y:render   # render manifests/dashboards.yaml locally for review (git-ignored)
```

Two upstream dashboards use a variable named `cluster` for something other than the Kubernetes cluster. In `sync-job.yaml`, each one has a `variables` override that adds a `k8s_cluster` variable as the cluster picker:

- CloudNativePG uses `cluster` for the Postgres cluster. The fleet keeps that name in the `pg_cluster` label and uses `cluster` only for the Kubernetes cluster. The override makes the `cluster` variable list the `pg_cluster` values.
- The etcd mixin fills its `cluster` variable from the `job` label and filters on `job="$cluster"`. With the `k8s_cluster` picker, that job variable keeps working.

For the CloudNativePG dashboard to list the databases of a cluster, the CNPG series of that cluster must carry `pg_cluster`. The [labels section of the shipping guide](../docs/05-shipping-metrics-guide.md#labels) shows the relabel rule. o11y, azad and harbor apply this rule.

The set contains a dashboard for everything that at least two clusters run:

- The dotdc Kubernetes views and system dashboards.
- The kube-prometheus mixin dashboards (kubelet, scheduler, controller manager, proxy, API server, compute resources, networking, persistent volumes, node exporter USE method).
- Node Exporter Full.
- etcd.
- vmagent.
- Cilium and Hubble.
- Flux.
- Envoy Gateway.
- CloudNativePG.

The configuration disables the Windows, AIX, macOS, Prometheus, Alertmanager and Grafana-overview dashboards from the mixin bundle. The render sorts the documents by name, so an unchanged upstream renders byte-identical output. The content layer of the artifact then keeps its digest across publishes. Only the revision and timestamp annotations of the manifest change. So after a publish with no upstream change, the Flux re-apply changes nothing.

The configuration pins the upstream sources that move: Cilium by release tag and Flux by commit. Where the VictoriaMetrics chart tracks a source at `master`, the configuration does the same.

## Adding a dashboard

1. Add the URL of the dashboard under `sources`.
2. If the upstream dashboard has no variable that lists the `cluster` label, add a `variables` override for it under `dashboards`. Set `cluster.query` to a `label_values()` query, for example `label_values(kube_node_info, cluster)`. The key is the slug of the dashboard title: `Kubernetes / Views / Pods` becomes `kubernetes-views-pods`.
3. Run the render task.
4. Review the output locally.
5. Commit the configuration change. CI then renders and publishes the bundle.

If the VictoriaMetrics chart also imports the dashboard, keep the dashboard out of `defaultDashboards.sources` of the chart. Otherwise the two compete for the same Grafana uid.
