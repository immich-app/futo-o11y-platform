#!/usr/bin/env bash
#MISE description="Create the CRDs that other apps consume on $ENVIRONMENT, before Flux starts"
# Flux installs the charts later and takes over these CRDs. Existing CRDs
# belong to Flux, so a rerun, even from an older checkout, never changes them.
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

crds="$(helmfile --quiet --file crds.yaml --environment "$ENVIRONMENT" template --include-crds --skip-deps |
    yq eval-all --exit-status 'select(.kind == "CustomResourceDefinition")')"
existing="$(kubectl get crd --output jsonpath='{.items[*].metadata.name}')"
missing="$(EXISTING="$existing" yq eval-all \
    'select([.metadata.name] - (strenv(EXISTING) | split(" ")) | length > 0)' <<<"$crds")"

if [[ -n "$missing" ]]; then
    kubectl create --filename - <<<"$missing"
else
    echo "every CRD exists"
fi
