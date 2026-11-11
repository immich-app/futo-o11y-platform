# NB_MANAGEMENT_URL mirrors yucca (the Cloud default). netbirdSetupKey comes
# from NETBIRD_TALOS_SETUP_KEY through topf.yaml, which the //talos tasks set.
{{- $key := .Data.netbirdSetupKey | trim }}
{{- if not $key }}{{ fail "netbirdSetupKey is empty; run topf through the //talos mise tasks" }}{{ end }}
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: netbird
environment:
  - NB_SETUP_KEY={{ $key }}
  - NB_MANAGEMENT_URL=https://api.netbird.io
