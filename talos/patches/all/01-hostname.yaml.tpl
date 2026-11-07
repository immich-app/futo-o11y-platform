# `auto: "off"` must be quoted: YAML 1.1 parses bare `off` as the boolean
# false, but the AutoHostnameKind enum needs the literal string.
apiVersion: v1alpha1
kind: HostnameConfig
auto: "off"
hostname: {{ .Node.Host }}
