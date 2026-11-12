#!/usr/bin/env bash
#MISE description="Render manifests/dashboards.yaml (git-ignored) from the upstream sources in sync-job.yaml"
# Shared Grafana dashboards: the VictoriaMetrics sync-job, in generate mode,
# fetches them from upstream and patches them for the fleet (cluster variable
# and filters, Fleet datasource, shared folder). CI publishes the output.
# The yq steps:
#   1. Pin every datasource-type template variable to the Fleet datasource.
#      The sync-job leaves them free, and Grafana would otherwise open a shared
#      board on the default (tenant-scoped) datasource and show only this
#      cluster.
#   2. Sort the documents. The sync-job emits the kube-prometheus bundle in map
#      order, and sorting makes an unchanged upstream render byte-identical, so
#      the artifact's content layer keeps its digest.
set -euo pipefail

docker run --rm -e OUTPUT=- -e CONFIG=/config/sync-job.yaml -e NAMESPACE=o11y -e RELEASE=shared -e OWNER_REFERENCES=false \
    -v "$PWD:/config:ro" ghcr.io/victoriametrics/sync-job:v0.0.18 |
    yq '(select(.kind == "GrafanaDashboard") | .spec.json) |= (fromjson | .templating.list[] |= (select(.type == "datasource") |= (.regex = "/^VictoriaMetrics Fleet$/" | .current = {"text": "VictoriaMetrics Fleet", "value": "VictoriaMetricsFleet"})) | tojson)' |
    yq eval-all '[.] | sort_by(.metadata.name) | .[] | splitDoc' >manifests/dashboards.yaml
