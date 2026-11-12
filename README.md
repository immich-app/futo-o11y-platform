# FUTO O11y Platform

This repository holds the central observability platform for FUTO services. Each environment has one Talos Kubernetes cluster. The cluster spans multiple OVH data centers, and Flux manages it. The cluster hosts the metrics, dashboards and alerting stack. It is also the central metrics store: other FUTO clusters remote-write their metrics into it.

The design gives geographic resilience, but you operate only one cluster. Three control planes in low-latency data centers hold one etcd quorum. Three bare-metal workers run the observability workload. All nodes communicate over a private OVH vRack.

Status: both environments, `o11y-staging` and `o11y-production`, are built and running.

## Documentation

| Guide                                                                             | Covers                                                                                                |
| --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| [01: Bootstrap](./docs/01-bootstrap-guide.md)                                     | Standing up an environment: one-time prep, Terragrunt apply order, operator access, common operations |
| [02: Infrastructure architecture](./docs/02-infrastructure-architecture-guide.md) | OVH compute, hardware specs, vRack networking, IPLB ingress, cost                                     |
| [03: Cluster architecture](./docs/03-cluster-architecture-guide.md)               | Talos, Kubernetes, host firewall, and Flux GitOps                                                     |
| [04: Application architecture](./docs/04-application-architecture-guide.md)       | Envoy ingress, VictoriaMetrics central store, Grafana, CloudNativePG, supporting operators            |

## Repository layout

```text
terraform/modules/
├── root.hcl                  # included by every module: S3 backend + per-env .terragrunt-cache/<env>
├── ovh/account/              # cloud project, vRack, private network, CPs, workers, IPLB, DNS
├── netbird/cluster/          # per-env mesh: vRack route, mesh-gateway VIP + DNS, pod egress, policies
├── rootly/cluster/           # Rootly service, heartbeats, alert sources, Zulip workflows, status page
├── netbox/cluster/           # IPAM registration of the ranges the other modules allocate
├── talos/cluster/            # Talos secrets bundle (state only), read by topf
└── victoria-metrics/cluster/ # vmauth mesh + public URLs in the Infisical shared project

talos/
├── <env>/topf.yaml           # nodes, versions and network values per environment
├── patches/                  # machine-config patches: all/, control-plane/, worker/
├── schematics/               # Talos Factory schematics (control plane, worker)
├── mise-tasks/               # apply, render and talosconfig tasks
└── bin/talos-secrets         # topf secrets provider: reads the bundle from Terraform state

bootstrap/                    # bring-up stages (mise.toml, mise-tasks/), kustomize/ (bootstrap Secrets), helmfiles for CRDs, CoreDNS + Flux

kubernetes/
├── apps/
│   ├── base/<app>/       # ks.yaml (the app's Flux Kustomization) + app/ (chart source + manifests)
│   └── <env>/<ns>/       # namespace overlay: which base apps run; deltas from base as patches/<app>.yaml
├── components/           # shared kustomize Components (targetNamespace replacement)
└── clusters/
    └── <env>/
        ├── apps.yaml             # cluster-apps entry point (the Flux Instance points here)
        └── cluster-settings.yaml # per-env CLUSTER_* ConfigMap (BOOTSTRAP_* comes from Terraform)
```

The Terraform state is in S3 under `yucca/o11y/v3/<module>/<env>`. Each environment has its own Terragrunt working directory. When you change `ENVIRONMENT`, you do not have to run init again. The secrets, the state bucket keys and the API tokens come from Infisical. The `//:tg` wrapper runs Terragrunt inside `infisical run`, and `terraform/modules/root.hcl` maps the Infisical names to the module inputs.

> [!IMPORTANT]
> Set `ENVIRONMENT` to `staging` or `production` before you run a task. If it is unset, the tasks read the Infisical `dev` environment and the Terraform state of the `development` environment.
