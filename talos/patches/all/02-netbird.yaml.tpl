# NB_MANAGEMENT_URL mirrors yucca (the Cloud default). The //talos tasks set
# NETBIRD_TALOS_SETUP_KEY from Infisical.
{{- $key := env "NETBIRD_TALOS_SETUP_KEY" | trim }}
{{- if not $key }}{{ fail "NETBIRD_TALOS_SETUP_KEY is unset; run topf through the //talos mise tasks" }}{{ end }}
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: netbird
environment:
  - NB_SETUP_KEY={{ $key }}
  - NB_MANAGEMENT_URL=https://api.netbird.io
