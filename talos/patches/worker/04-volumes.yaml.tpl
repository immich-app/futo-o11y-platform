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
{{- range .Data.workerDataVolumes }}
---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: {{ . }}
provisioning:
  diskSelector:
    match: {{ $.Data.workerDataDiskMatch | squote }}
  minSize: 100GB
  grow: true
{{- end }}
