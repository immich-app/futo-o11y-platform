include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."

  extra_arguments custom_vars {
    commands = get_terraform_commands_that_need_vars()
  }
}

# storage.tf finds the env's project with a data source rather than reading
# ovh/account's outputs, so this edge is what orders `run --all`: after
# ovh/account on apply, before it on destroy.
dependencies {
  paths = ["../../ovh/account"]
}
