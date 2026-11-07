# NB_MANAGEMENT_URL mirrors yucca (the Cloud default). The //talos tasks set
# NETBIRD_SETUP_KEY from talos/.env through `op run`.
{{- $key := env "NETBIRD_SETUP_KEY" | trim }}
{{- if or (not $key) (hasPrefix "op://" $key) }}{{ fail "NETBIRD_SETUP_KEY is unset or an unresolved op:// reference; run topf through the //talos mise tasks" }}{{ end }}
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: netbird
environment:
  - NB_SETUP_KEY={{ $key }}
  - NB_MANAGEMENT_URL=https://api.netbird.io
