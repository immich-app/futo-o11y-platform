#!/usr/bin/env bash
#MISE description="Apply the machine configurations to the $ENVIRONMENT nodes that are still in maintenance mode"
#MISE depends=["//talos:talosconfig"]
# A new node accepts an unauthenticated configuration only on its public IP,
# because NetBird does not run yet, so the public IPs come from the OVH
# outputs. A configured node is on the mesh and routes the vRack, so it
# answers an authenticated call on its private IP; such a node is skipped,
# and the stage can run again. The rendered files hold the cluster's private
# keys, so they go to a temporary directory that is deleted on exit.
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

nodes="$(mise run //terraform/ovh:output -- -json |
    jq -r '[.controlplane_nodes.value, .worker_nodes.value][][] | "\(.name) \(.public_ip) \(.private_ip)"' | sort)"
hosts="$(yq '.nodes[].host' "$TOPFCONFIG" | sort)"
if [[ "$hosts" != "$(cut -d' ' -f1 <<<"$nodes")" ]]; then
    echo "the nodes in $TOPFCONFIG and in the OVH outputs differ:" >&2
    diff <(echo "$hosts") <(cut -d' ' -f1 <<<"$nodes") >&2 || true
    exit 1
fi

pending=()
while read -r name public private; do
    if talosctl --nodes "$private" --endpoints "$private" version >/dev/null 2>&1; then
        echo "$name is configured"
    else
        pending+=("$name $public")
    fi
done <<<"$nodes"
if ((${#pending[@]} == 0)); then
    echo "every node is configured"
    exit 0
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
# topf reads its global --nodes-filter from TOPF_NODES_FILTER.
printf -v filter '%s|' "${pending[@]%% *}"
TOPF_NODES_FILTER="^(${filter%|})$" mise run //talos:render "$dir"

failed=0
for entry in "${pending[@]}"; do
    name="${entry%% *}"
    public="${entry#* }"
    if talosctl apply-config --insecure --nodes "$public" --file "$dir/$name.yaml"; then
        echo "applied the configuration to $name"
    else
        echo "FAILED: $name ($public). A node configured a moment ago is not on the mesh yet; run the task again." >&2
        failed=1
    fi
done
exit "$failed"
