#!/usr/bin/env bash
#MISE description="Apply the namespaces, Secrets and bootstrap-settings ConfigMap Flux needs to $ENVIRONMENT"
# Needs an `infisical login` session on the mesh. <env>:/tf imports the
# project's global folder.
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

kustomize build --load-restrictor LoadRestrictionsNone "kustomize/$ENVIRONMENT" |
    infisical run --silent --log-level warn --env "$ENVIRONMENT_SHORT" --path /tf --path /ci -- flux envsubst --strict |
    kubectl apply --server-side --force-conflicts --filename -
mise run //terraform/netbird:output -- -raw bootstrap_settings |
    kubectl apply --server-side --force-conflicts --filename -
