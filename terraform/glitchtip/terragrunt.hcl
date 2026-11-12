include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

# storage.tf finds the env's project with a data source rather than reading
# terraform/ovh's outputs, so this edge is what orders `run --all`: after
# terraform/ovh on apply, before it on destroy.
dependencies {
  paths = ["../ovh"]
}
