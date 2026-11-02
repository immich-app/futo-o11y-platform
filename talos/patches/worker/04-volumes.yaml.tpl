apiVersion: v1alpha1
kind: VolumeConfig
name: EPHEMERAL
provisioning:
  diskSelector:
    match: system_disk
  minSize: 256GB
  maxSize: 256GB
  grow: false
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: hostpath
provisioning:
  diskSelector:
    match: system_disk
  minSize: 20GB
  grow: true
---
# Spare-disk volumes; the CEL selectors are in topf.yaml.
apiVersion: v1alpha1
kind: UserVolumeConfig
name: local-hostpath
provisioning:
  diskSelector:
    match: {{ .Data.workerDataDiskMatch | squote }}
  minSize: 100GB
  grow: true
{{- if hasKey .Data "workerDataDisk2Match" }}
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: local-hostpath-2
provisioning:
  diskSelector:
    match: {{ .Data.workerDataDisk2Match | squote }}
  minSize: 100GB
  grow: true
{{- end }}
