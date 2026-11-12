#!/usr/bin/env bash
#MISE description="Apply the machine configs to the given $ENVIRONMENT nodes, one node at a time, confirming each diff (--dry-run only shows the diffs and exits 2 when there are changes)"
#USAGE flag "--dry-run" help="Only show the changes"
#USAGE arg "<node>" var=#true help="Node names, the hosts in talos/$ENVIRONMENT/topf.yaml"
#USAGE complete "node" run="mise exec -- sh -c 'yq \".nodes[].host\" \"$TOPFCONFIG\"'"
# Takes node names (the hosts in topf.yaml) and never selects the whole
# cluster by default. topf treats a filter that matches no node as success, so
# every name is checked first.
# The NetBird setup key (NETBIRD_TALOS_SETUP_KEY, which the netbird module
# writes) comes from this environment's /tf in Infisical. Nothing masks it, so
# a diff that changes the netbird patch shows the key. `infisical run` would
# turn topf's exit code 2 (changes found) into 1, so only the key is read.
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

nodes=()
eval "nodes=(${usage_node?})"
for node in "${nodes[@]}"; do
    if ! NODE="$node" yq -e '.nodes[] | select(.host == strenv(NODE))' "$TOPFCONFIG" >/dev/null 2>&1; then
        echo "$node is not a node in $TOPFCONFIG" >&2
        exit 1
    fi
done
printf -v filter '%s|' "${nodes[@]}"
filter="^(${filter%|})$"

NETBIRD_TALOS_SETUP_KEY="$(infisical secrets get NETBIRD_TALOS_SETUP_KEY --silent --log-level warn --env "$ENVIRONMENT_SHORT" --path /tf --plain)"
export NETBIRD_TALOS_SETUP_KEY
topf --nodes-filter "$filter" apply --dry-run="${usage_dry_run:-false}"
