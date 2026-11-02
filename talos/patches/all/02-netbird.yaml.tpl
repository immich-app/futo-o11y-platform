# NetBird overlay, the node management mesh. Operators reach the vRack IPs
# through the NetBird route (server-side, masqueraded to a routing peer's vRack
# IP). NB_MANAGEMENT_URL mirrors yucca (the Cloud default). The //talos tasks
# run topf under `op run`, which sets NETBIRD_SETUP_KEY from the env vault
# (talos/.env) and conceals it in topf's output.
{{- $key := env "NETBIRD_SETUP_KEY" | trim }}
{{- if or (not $key) (hasPrefix "op://" $key) }}{{ fail "NETBIRD_SETUP_KEY is unset or an unresolved op:// reference; run topf through the //talos mise tasks" }}{{ end }}
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: netbird
environment:
  - NB_SETUP_KEY={{ $key }}
  - NB_MANAGEMENT_URL=https://api.netbird.io
