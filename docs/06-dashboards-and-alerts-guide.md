# Grafana dashboards and alerts

o11y's Grafana shows the dashboards and alert rules that each project ships to it. Nobody makes a dashboard or an alert by hand in the UI and leaves it there to decay. Each dashboard and each alert is a `grafana-operator` custom resource (CR). It arrives through one of two delivery models, and it goes into a folder for its project.

## Folders are the project boundary

Each project gets a Grafana folder with the name of the project. The dashboards and the alert rule groups of the project go into that folder:

| Folder           | Owner                                                                                                                                                                                           | Delivered by                                                                                                     |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `yucca`          | the yucca cluster/product                                                                                                                                                                       | yucca's signed OCI bundle (Model A)                                                                              |
| `o11y`           | this cluster's own dashboards/alerts                                                                                                                                                            | authored in this repo (Model B)                                                                                  |
| `harbor`         | the Harbor clusters (harbor-infra-prod/staging)                                                                                                                                                 | harbor-o11y's key-signed OCI bundle (Model A, anonymous-pull registry)                                           |
| `fip`            | the FUTO internal platform cluster (azad)                                                                                                                                                       | futo-internal-platform's signed OCI bundle (Model A)                                                             |
| `version`        | the Immich version worker (Cloudflare)                                                                                                                                                          | immich-app/version's signed OCI bundle (Model A), including recording rules                                      |
| `fmeet`          | the fmeet serverless workers (Cloudflare)                                                                                                                                                       | fmeet's unsigned OCI bundle (Model A, private gitlab.futo.org registry pulled with a deploy token)               |
| `bootstrap`      | the bootstrap DOKS cluster (palpatine)                                                                                                                                                          | bootstrap's key-signed GitLab OCI bundle (Model A, anonymous-pull registry: infra/bootstrap is a public project) |
| `geoshenanigans` | the geoshenanigans geocoder nightly build and its watchdog (GitHub Actions jobs pushing straight to the public gateway), and the tiles.immich.cloud worker (Cloudflare, on the serverless path) | immich-app/geoshenanigans's signed OCI bundle (Model A)                                                          |

When you add a project, add a folder for it. You scope dashboards, alerts, and (later) permissions to that folder.

## Tags cut across folders

A folder puts a dashboard under exactly one project. A tag is a second, independent axis: the signal type (`metrics`, `logs`) or the layer (`infra`, `k8s`, `app`). The Grafana dashboard browser filters on tags across all folders at once. Grafana stores tags inside the dashboard JSON model, and `grafana-operator` exposes no field to inject them. Thus you can set tags only where the JSON is written:

- Bundle (Model A) and first-party (Model B) dashboards that you write: set `tags` in the dashboard JSON before you ship it. The folder is your project, and the tags give the signal and the layer across folders.
- Dashboards pulled from grafana.com or a raw URL (`spec.grafanaCom` / `spec.url`, for example the grafana-operator dashboard): these dashboards carry the tags that upstream set. Unless o11y vendors (copies) the JSON inline, it cannot add or normalize these tags. A vendored copy loses the live reference and the `resyncPeriod` auto-updates. Thus, leave these tags as they are.

## Model A: a project ships a signed OCI manifest bundle

yucca ships this way (immich-app/yucca#315, see `o11y/README.md` in that repo). The project's CI renders each dashboard into a self-contained `GrafanaDashboard` CR, with the JSON embedded as `spec.gzipJson`. The CI also renders any `GrafanaAlertRuleGroup` CRs and a `GrafanaFolder`. It pushes all of them as one signed OCI artifact (`flux push artifact` + cosign keyless). o11y consumes the whole artifact with a single Flux `OCIRepository` + `Kustomization`. New dashboards and alerts arrive automatically with the next artifact.

The o11y consumer side is defined once, in `kubernetes/apps/base/tenants/yucca/bundle.yaml`. Each tenant has one such file, and `base/tenants/kustomization.yaml` lists these files. The `o11y` overlay of each env pulls in that list. kustomize-controller applies a bundle with its own cluster-wide rights (no `serviceAccountName`). The signature check pins the bundle to the workflow of its repo. o11y accepts this setup while every writer of a bundle repo is also a writer of futo-o11y-platform:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata: { name: yucca-o11y, namespace: flux-system }
spec:
  interval: 1m
  url: oci://ghcr.io/immich-app/futo-applications-platform/o11y-manifests
  ref:
    tag: main # tracks every merge; no digest, or auto-updates stop
  verify: # gate on the CI cosign signature
    provider: cosign
    matchOIDCIdentity:
      - issuer: "^https://token\\.actions\\.githubusercontent\\.com$"
        subject: "^https://github\\.com/immich-app/futo-applications-platform/\\.github/workflows/o11y\\.yml@refs/(heads/main|tags/v[^@]+)$"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: yucca-o11y, namespace: flux-system }
spec:
  interval: 10m
  sourceRef: { kind: OCIRepository, name: yucca-o11y }
  path: ./
  prune: true
  targetNamespace: o11y
  dependsOn: [{ name: grafana-operator }]
```

The CRs in the bundle carry reasonable defaults (`instanceSelector: {dashboards: grafana}`, `folderRef: <project>`, `resyncPeriod`), so o11y applies them as they are. The GHCR package must be public, or the OCIRepository must set `secretRef`. Also, source-controller needs egress to sigstore for `verify`.

### Model A from a private registry

The yucca bundle is a public GHCR package, so its `OCIRepository` needs no
credential. A private project that publishes to its own forge has a private
registry, and there is no way around this. For example, fmeet ships to
`gitlab.futo.org:5050`, where its private GitLab project is.

GitLab's `container_registry_access_level` takes only `disabled` / `private` /
`enabled`, and `enabled` still means "everyone with access". Of all the access
levels for project features, only `pages_access_level` accepts `public`. Thus a
private project cannot expose a publicly pullable registry. `/jwt/auth` refuses
an anonymous pull scope outright. The registry of a public project is the
opposite case, and the end of this section covers it.

Such a project thus needs two additions:

- A read-only pull credential: a GitLab _project deploy token_ scoped to
  `read_registry` gives the least access possible. It can pull only from the
  registry of that one project, and you can revoke it without changes to an
  account. Its username and password go into 1Password as two separate manual
  secrets. Each secret holds its value in the `password` field of its item. The
  manual-secrets module creates only items of the password category. Thus the
  two parts of the credential go into two items, not into extra fields on one
  item.
- An ExternalSecret that renders the credential as a `dockerconfigjson`: it is
  in `flux-system`, because the `OCIRepository` is in that namespace and a
  `secretRef` resolves in its own namespace. It reads the two items by name and
  builds the docker configuration around them from a template. See the
  `ExternalSecret` in `base/tenants/fmeet/bundle.yaml`.

Both items go in the global `o11y_tf` vault, and the cluster reads them through
the `onepassword` store. They do not go in `shared_tf`, because that vault is
for credentials that more than one project consumes. This cluster is the only
thing that pulls the bundle.

They also do not go in a per-environment o11y vault. There is one fmeet project
registry, so there is one token, and it is the same in every environment. The
`o11y-manual-secrets` module in core-infra-tf declares them, and an operator
fills them in by hand in `o11y_tf_manual`.

The `onepassword` ClusterSecretStore reads the global `o11y_tf` vault. The other
stores read `shared_tf` and the per-environment o11y vaults. Terragrunt consumes
the other items in the global vault, and nothing inside the cluster reads them.

The key under `auths` must match the pull host of the `OCIRepository` exactly,
including the port (`gitlab.futo.org:5050`, not `gitlab.futo.org`). A mismatch
shows only as an authentication failure, and the failure does not point at the
cause.

An anonymously pullable registry avoids all of this, so the `OCIRepository`
needs no `secretRef`. harbor-o11y uses this method. Its bundle is at
`registry.futo.org/harbor/o11y-manifests`, where `harbor/` allows anonymous
reads. bootstrap uses the same method on `gitlab.futo.org` itself.
`infra/bootstrap` is a public project, so `/jwt/auth` grants an anonymous pull
on `gitlab.futo.org:5050/infra/bootstrap/o11y-manifests`. No deploy token is
necessary.

Unless the publisher signs with a key pair, the `OCIRepository` of such a bundle
also omits `verify:`. harbor-o11y and bootstrap sign with a key pair.
The CI of harbor-o11y signs the digest with a key that its infrastructure
terraform mints. That repo commits the public half as `cosign.pub`.
`base/tenants/harbor` carries the public half as the `harbor-o11y-cosign`
Secret, which `verify.secretRef` references.

bootstrap's key pair is hand-generated. The private half is in its
`futo_bootstrap_tf` vault, and the public half is in its `o11y/cosign.pub`.
`base/tenants/bootstrap` carries it as `bootstrap-o11y-cosign`. Keyless cosign
mints its certificate from public Fulcio against the OIDC identity of the CI.
Fulcio accepts `gitlab.com` but not a self-hosted forge. Thus you cannot copy
the keyless block above to a bundle on a self-hosted forge.

### Recording rules in a bundle

If a project records its own series, its bundle can also ship `VMRule`s. immich-app/version does this. o11y's `vmalert` reads only o11y's tenant and writes with o11y's identity labels. Thus it must not evaluate these rules. The setup has three parts:

- The tenant's Kustomization in `base/tenants/<tenant>/bundle.yaml` sets `commonMetadata.labels` `o11y.futo.org/tenant: <tenant>` on everything that it applies. Flux overrides any value that the bundle sets for that key, so a bundle cannot claim the label of another tenant. Like the other bundles, it depends only on `grafana-operator`. The `VMRule` CRD comes from `victoria-metrics`, and it is always installed after the cluster is up. On a fresh bootstrap, the bundle fails its dry-run until then, and Flux retries it.
- o11y's own `vmalert` (`base/victoria-metrics/app/helmrelease.yaml`) selects every `VMRule` that does not have that label.
- The tenant's `VMAlert` (`base/victoria-metrics-users/app/vmalert-<tenant>.yaml`) selects the label in the `o11y` namespace. It also matches `kustomize.toolkit.fluxcd.io/name: <tenant>-o11y`. kustomize-controller sets this label on every object that it applies, so no other bundle can feed rules to this `VMAlert`. It reads `/select/<tenant>/prometheus` and writes through the multitenant insert endpoint. It sets the tenant's identity labels as `externalLabels`, and these labels route the results back into the tenant.

These `externalLabels` do not pin the tenant. They displace a label with the same name from the query result, and `vmalert` keeps that label as `exported_<name>`. But a group's or a rule's own `labels:` override the `externalLabels`. If a rule sets `project` or `cluster`, its results go under another tenant.

Thus a bundle must not set identity labels on its groups or rules. The identity labels are `project`, `cluster`, `env`, `provider`, `region`, `vm_account_id`, and `vm_project_id`. o11y does not enforce this. The render script of immich-app/version rejects these labels before it publishes.

Per-group `tenant` on a `VMRule` is in VictoriaMetrics Enterprise only, so each tenant with rules gets its own `vmalert`. If a rule joins a recorded series with an aggregate, the rule must match on the labels of the aggregate (`and on(client_ip)`). The recorded series carries the external labels, and the aggregate does not.

## Model B: authored in this repo (o11y's own)

This cluster's own dashboards and alerts are under `kubernetes/apps/base/grafana/app/`, and they deploy with the grafana Flux Kustomization:

- Dashboards: `base/grafana/app/dashboards.yaml` is a single file. It holds the `o11y` `GrafanaFolder` and one `GrafanaDashboard` document per dashboard, with `folderRef: o11y`. Use any source for the JSON that fits. Examples are `spec.grafanaCom` or `spec.url` to a grafana.com or raw dashboard (the grafana-operator dashboard), and `spec.gzipJson`. Map the dashboard `__inputs` (for example `DS_PROMETHEUS`) to `datasourceName: VictoriaMetrics`, which serves o11y's own tenant.
- Alerts: `base/grafana/app/alerts-*.yaml`, a `GrafanaAlertRuleGroup` with `folderRef: o11y`.

CRs for another project that are written in this repo read their data from another tenant. Thus they use the Fleet datasource, as a bundle does (see Datasources and tenants).

## Shared dashboards

Cluster-generic boards are in the `Shared` folder once, not in each tenant bundle. The VictoriaMetrics sync-job in generate mode renders them from their upstream sources. Each board filters on a multi-select `$cluster` variable and is pinned to the `VictoriaMetrics Fleet` datasource, so one copy serves every cluster. For the list of boards and how to add one, see [`o11y/README.md`](../o11y/README.md). A tenant bundle must not ship its own copy of a board that is in `Shared`.

## Alerting

Contact points: each destination has one `GrafanaContactPoint`. Alerts go to [Rootly](https://rootly.com). Each project has one webhook contact point, `rootly-<project>` in `base/grafana/app/contactpoint-rootly-alerts.yaml`. Each of these contact points posts to the Rootly alert source of its project, with the source's own secret. Two more contact points exist: `rootly-heartbeat` for the dead man's switch, and `rootly-heartbeat-remote` for the env's remote cluster (`CLUSTER_REMOTE_HEARTBEAT` in cluster-settings: father on production, luke on staging).

`o11y-remote-heartbeat` in `alerts-fleet.yaml` fires only while metrics from that cluster arrive. If the cluster goes dark after the first ping of the heartbeat, the pings stop. Rootly then alerts the yucca topic within about 8 minutes, and it stays alerted until metrics return. A heartbeat that never got a ping stays waiting and cannot alert. The contact point sends no resolve message, because Rootly counts any POST as a ping.

The `deployment/modules/rootly/cluster` Terraform module manages the alert sources, the per-project services, and their credentials. It writes the webhook URL of each source into the env 1Password vault as `ROOTLY_ALERTS_<PROJECT>_URL`. The secret travels in the `secret` query parameter of that URL, because Rootly's Grafana endpoint reads it from no other place. An ExternalSecret materializes the vault item into the Secret that the contact point reads through `receivers[].valuesFrom`. The value is never in git.

A resolved Grafana notification resolves the Rootly alert. Repeat notifications for a group that is still firing merge into its open Rootly alert by the Grafana group key. Thus each group posts to Zulip only twice: once at fire time and once at resolve time. Until escalation policies page someone, a high-urgency alert that stays open and unacknowledged also gets a daily reminder in its topic.

The Rootly alert description is the Grafana notification message, which the `rootly.message` template in `base/grafana/app/notificationtemplate-rootly.yaml` renders. For each firing alert, it shows the `summary` and `description` annotations. Then it shows links to the rule, to the dashboard and the runbook where set, and to a silence. The message covers up to five alerts per group. In Zulip, fired posts and reminders carry that description under the title line.

Rootly derives the alert urgency from the `severity` label (`critical` -> High, `warning` -> Medium, otherwise Low). Until escalation policies exist, Rootly workflows forward fired and resolved alerts from the Rootly cloud to Zulip. They use the Slack-compatible incoming webhook of Zulip. The alerts of each project land in the `yucca-alerts` channel (harbor in `harbor-alerts`) under a `<project>-<env>` topic.

An expired heartbeat raises a Rootly alert with no Grafana payload, and the forwarding workflows cannot match it. Thus a separate pair of workflows for each heartbeat matches the alert by heartbeat id. This pair posts the expiry and the recovery to the topic of the project that the heartbeat watches.

Contact points are in the shared Grafana Postgres, so every replica has the same ones. The replicas form an HA gossip cluster, so a firing alert notifies once, not once per replica.

Rootly's Grafana integration: in addition to the alert sources, Rootly has an account-level Grafana integration (Integrations > Grafana). The integration takes this cluster's Grafana URL and an Admin service account token. With it, Rootly can deep-link rules and snapshot dashboards into incidents. Rootly exposes no API or Terraform surface for it, so an operator installs it by hand once per env.

The `deployment/modules/grafana/cluster` module owns the `rootly` service account and its token. It writes the token to the env vault as `ROOTLY_GRAFANA_SERVICE_ACCOUNT_TOKEN`. To install the integration, paste that token and `https://grafana.<env domain>` into Integrations > Grafana in Rootly. The module is separate from `rootly/cluster`, so a plan of `rootly/cluster` still works while Grafana is down.

Routing: one `GrafanaNotificationPolicy` routes by the `project` label first and by the `grafana_folder` label second. `project` is the same identity label that every shipper stamps on its series (see the [shipping guide](05-shipping-metrics-guide.md#labels)). If the rule sets it as a rule label, or if the query keeps it in its aggregation, the alert instance carries it. Grafana adds `grafana_folder` from the folder that each rule files into. Thus rules without a `project` label still route by their folder:

```yaml
route:
  receiver: rootly-o11y # default / catch-all
  routes:
    - object_matchers: [["project", "=", "yucca"]]
      receiver: rootly-yucca
    - object_matchers: [["project", "=", "o11y"]]
      receiver: rootly-o11y
    - object_matchers: [["grafana_folder", "=", "yucca"]]
      receiver: rootly-yucca
    - object_matchers: [["grafana_folder", "=", "o11y"]]
      receiver: rootly-o11y
```

A rule that one project owns sets `project: <project>` as a rule label. This label routes the rule. If the query aggregates the label away, the rule label still pins it. If a shared rule must go to each remote cluster's own team, it keeps `project` in its aggregation and sets no `project` rule label. A rule label overrides the series label, and then the firings of every cluster go to one team.

`o11y-external-secret-not-ready` in `alerts-fleet.yaml` works this way (`by (project, env, cluster, ...)`). If a firing is for a project with no route of its own, it falls through to the `o11y` folder route.

The other fleet rule, `o11y-cluster-silent`, is o11y's own rule. It reads vminsert's per-tenant ingestion counters, which are in o11y's own tenant. It aggregates `by (accountID, projectID)` and sets `project: o11y`. So if a tenant stops ingesting, the page goes to o11y, not to the owner of the cluster.

By design, the rule reads nothing from the silent cluster. The multitenant path stops returning a tenant with no ingestion since UTC midnight. So any rule computed from a dark cluster's own history goes empty, and resolves, at the first midnight of the outage. If a project wants its own page for that case, it ships an absence rule in its folder. That rule is gated on o11y's own current `up`, not on the silent cluster's history (yucca's `ClusterMetricsGone*`, for example).

Notifications group by `project`, `grafana_folder`, `alertname` and `cluster`. So if the same rule fires in two clusters, two grouped notifications arrive, not one blended message. `o11y-cluster-silent` carries no `cluster` label, so grouping also uses `accountID` and `projectID`. Only that rule sets these two labels, and each silent tenant arrives as its own notification.

Datasources and tenants: two Prometheus-type datasources are in front of the same store. `VictoriaMetrics` (uid `VictoriaMetrics`, the default) carries this cluster's own tenant in its URL. It goes through the `self-select` vmauth, which routes only that path. So anything that does not pick a datasource explicitly sees only o11y's series. `VictoriaMetrics Fleet` (uid `VictoriaMetricsFleet`) reads the multitenant endpoint across all tenants. This includes tenant 0, where clusters without a registry rule land.

Fleet is the explicit opt-in for cross-cluster dashboards and rules (`alerts-fleet.yaml`). The datasource URL carries the tenancy, never the dashboard JSON or the rule queries. Both filter and group on the `cluster` label, which the series keep in every tenant.

Thus the default datasource is correct only for o11y's own rules and boards. The series of every other project are in its own tenant (or tenant 0), and only `VictoriaMetrics Fleet` can see them. So a remote project uses Fleet everywhere. Here, a remote project is every bundle, and also another project's CRs that are written in this repo. A rule cannot use a `$datasource` variable, so every alert query node sets `datasourceUid: VictoriaMetricsFleet`. Dashboards use a `$datasource` variable with the regex `/^VictoriaMetrics Fleet$/`.

If a remote rule stays on the default datasource, it evaluates to NoData. The usual `noDataState: OK` keeps such a rule Normal through a real outage. Fleet serves every tenant, so a remote project also scopes each selector with `project="<project>"`. Without this scope, a generic rule (Flux, cert-manager, Kubernetes) fires on the clusters of other projects.

Alert rule anatomy: a `GrafanaAlertRuleGroup` has `folderRef: <project>`, an `interval`, and `rules[]`. Each rule has a query stage on a Prometheus datasource, and this stage feeds a `__expr__` threshold stage. The datasource uid is `VictoriaMetrics` for o11y's own rules. It is `VictoriaMetricsFleet` for the fleet rules and for the rules of every remote project (see Datasources and tenants). Each rule also has `labels` (at least `severity`) and `annotations`. The annotations are a one-line `summary`, a `description` of what to check, and optionally a `runbook_url`.

Rootly and Zulip show the `summary` and the `description` for every firing alert. See `base/grafana/app/alerts-o11y.yaml` for the pattern (a heartbeat plus target-down and ingestion-stalled rules). Rules that span clusters aggregate `by (cluster)`. Thus each cluster raises its own instance and carries its `cluster` label into notification grouping. Store-local rules (the heartbeat, ingestion-stalled) do not aggregate this way.

## If you ship metrics to this cluster and want dashboards/alerts

1. Pick a delivery model: Model A or Model B. Model A is recommended for a separate repo or cluster. In Model A, you own a signed bundle, and o11y adds one OCIRepository. In Model B, you open a PR that adds the CRs to `base/grafana`.
2. If your project has no folder yet, ask for one.
3. File everything that you ship under your project's folder.
4. Set `project: <project>` as a rule label on your rules. Folder routing is the fallback.
5. Ask for your project to be added to the `projects` list of the Rootly module. After an operator applies `deployment/modules/rootly/cluster` in both environments, you get these items:
   - A Rootly alert source
   - A service
   - Zulip delivery to `yucca-alerts` under a `<project>-<env>` topic
   - The `ROOTLY_ALERTS_<PROJECT>_URL` vault item
6. Open a second change in this repo with the `rootly-<project>` contact point, its ExternalSecret and the two routes in `base/grafana/app`.
7. Merge that change only after the apply, because the ExternalSecret needs the vault item (bootstrap: #388, then #389).
8. Query `VictoriaMetrics Fleet`, never the default `VictoriaMetrics` datasource. The default sees only o11y's own tenant (see Datasources and tenants).
9. In alerts, set `datasourceUid: VictoriaMetricsFleet` on every query node.
10. In dashboards, use a `$datasource` variable with the regex `/^VictoriaMetrics Fleet$/`.
11. Put `project="<project>"` in every selector.
12. Tag dashboards by signal and layer in the JSON (`metrics`, `logs`, `infra`, ...). The tags keep them filterable across folders (see Tags).
13. If an alert compares across clusters, aggregate it `by (cluster)`.
14. Stamp the five identity labels on your series (see the [shipping guide](05-shipping-metrics-guide.md#labels)). Per-cluster alerting needs these labels.

## How updates flow

- Model A: edit in the source repo and merge to `main`. CI then pushes the `:main` artifact (signed). o11y's OCIRepository picks it up within its `interval`. The Kustomization applies, and grafana-operator syncs. From end to end, this takes about a minute.
- Model B: open a PR in this repo with the CR change, and merge it. Flux then reconciles `base/grafana`.
