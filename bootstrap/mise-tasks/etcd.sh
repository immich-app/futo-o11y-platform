#!/usr/bin/env bash
#MISE description="Bootstrap etcd on $ENVIRONMENT's first control plane (waits until it is up)"
#MISE depends=["//talos:talosconfig"]
# Reaches the first control plane on its private IP, so the operator's NetBird
# route to the vRack must work.
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

cp="$(yq '.data.controlplaneIps[0]' "$TOPFCONFIG")"
deadline=$((SECONDS + 1200))
until out="$(talosctl --nodes "$cp" --endpoints "$cp" bootstrap 2>&1)" || [[ "$out" == *AlreadyExists* ]]; do
    if ((SECONDS > deadline)); then
        echo "etcd bootstrap on $cp did not succeed within 20 minutes: $out" >&2
        exit 1
    fi
    echo "etcd bootstrap on $cp: $out; checking again in 5s"
    sleep 5
done
echo "etcd is bootstrapped on $cp"
