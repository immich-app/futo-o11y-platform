#!/usr/bin/env bash
#MISE description="Write a 12h admin kubeconfig for $ENVIRONMENT to $KUBECONFIG"
#USAGE flag "--direct" help="Use the first control plane instead of the mesh endpoint"
# --direct is for bootstrap and DR, before the mesh gateway exists. TLS works on
# both endpoints: every control-plane IP is an apiserver cert SAN.
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

if [[ "${usage_direct:-false}" == true ]]; then
    host="$(yq '.data.controlplaneIps[0]' "$TOPFCONFIG")"
else
    host="kube.$(yq '.data.meshDnsZone' "$TOPFCONFIG")"
fi

umask 077
mkdir -p "$(dirname "$KUBECONFIG")"
config="$(topf kubeconfig)"
printf '%s\n' "$config" >"$KUBECONFIG"
kubectl config set-cluster "o11y-$ENVIRONMENT" --server "https://$host:6443"
kubectl config rename-context "topf@o11y-$ENVIRONMENT" "o11y-$ENVIRONMENT"
