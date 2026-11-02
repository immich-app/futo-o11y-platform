#!/usr/bin/env bash
#MISE description="Write the talosconfig for $ENVIRONMENT to $TALOSCONFIG"
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

umask 077
mkdir -p "$(dirname "$TALOSCONFIG")"
config="$(topf talosconfig)"
printf '%s\n' "$config" >"$TALOSCONFIG"
