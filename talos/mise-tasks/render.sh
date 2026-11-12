#!/usr/bin/env bash
#MISE description="Render $ENVIRONMENT's machine configs, secrets included, into <output>"
#USAGE arg "<output>" help="Directory for the rendered configs (use a temp dir)"
# The rendered files hold the cluster's private keys, so the output dir is
# required (topf's default ./output is inside the repo); use a temp dir.
set -euo pipefail
: "${ENVIRONMENT:?set ENVIRONMENT=staging (or production) first}"

NETBIRD_TALOS_SETUP_KEY="$(infisical secrets get NETBIRD_TALOS_SETUP_KEY --silent --log-level warn --env "$ENVIRONMENT_SHORT" --path /tf --plain)"
export NETBIRD_TALOS_SETUP_KEY
topf render --output "${usage_output?}"
