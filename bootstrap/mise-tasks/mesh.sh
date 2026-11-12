#!/usr/bin/env bash
#MISE description="Wait until the mesh endpoint of the $ENVIRONMENT apiserver answers"
# kube.<meshDnsZone> is the Envoy mesh gateway, which Flux installs, so the
# wait covers the first Flux sync. /readyz is open to anonymous callers
# (talos/patches/control-plane/03-kubernetes.yaml.tpl).
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

host="kube.$(yq '.data.meshDnsZone' "$TOPFCONFIG")"
deadline=$((SECONDS + 1800))
until curl --fail --silent --insecure --max-time 10 --output /dev/null "https://$host:6443/readyz"; do
    if ((SECONDS > deadline)); then
        echo "$host did not answer within 30 minutes" >&2
        exit 1
    fi
    echo "waiting for $host"
    sleep 15
done
echo "$host answers"
