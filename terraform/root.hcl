locals {
  env   = get_env("TF_VAR_env")
  stage = get_env("STAGE", "")

  # Files that change how every module plans, locally or in the CI plan job.
  # Marking them read makes a git-filtered plan (CI on pull requests) select
  # every module when one changes.
  shared_inputs = mark_glob_as_read("${get_repo_root()}/{terraform/mise.toml,.mise/**,.github/workflows/terraform.yaml}")
}

# Per-env working dirs, so switching ENVIRONMENT never reuses another env's
# initialized backend (including the copies dependency outputs are read from).
# The stage is hashed: a raw one containing "/../" can resolve into another
# env's directory.
download_dir = "${get_terragrunt_dir()}/.terragrunt-cache/${local.env}${local.stage != "" ? "-${sha256(local.stage)}" : ""}"

# The mise tg wrapper runs terragrunt inside `infisical run`, which puts the
# observability project's <env>:/tf (with its global import) and the shared
# project's global:/tf into the environment under their Infisical names.
# Every module gets every input; OpenTofu ignores the ones a module does not
# declare.
inputs = {
  env_short = get_env("ENVIRONMENT_SHORT")

  ovh_application_key    = get_env("OVH_APPLICATION_KEY")
  ovh_application_secret = get_env("OVH_APPLICATION_SECRET")
  ovh_consumer_key       = get_env("OVH_CONSUMER_KEY")

  netbird_tf_pat = get_env("NETBIRD_TF_PAT")

  netbox_url   = get_env("NETBOX_URL")
  netbox_token = get_env("NETBOX_API_TOKEN")

  rootly_api_token     = get_env("ROOTLY_API_TOKEN")
  rootly_zulip_webhook = get_env("ROOTLY_ZULIP_WEBHOOK")
}

generate "backend" {
  path      = "backend.tf"
  if_exists = "overwrite_terragrunt"
  # The contents carry the state bucket keys. A mutable file is written in
  # place instead of being stored in Terragrunt's persistent CAS and
  # hard-linked here, so no copy outlives download_dir.
  mutable  = true
  contents = <<EOF
terraform {
  backend "s3" {
    bucket = "${get_env("TF_STATE_S3_BUCKET")}"
    key    = "yucca/o11y/v3/${path_relative_to_include()}/${local.env}${local.stage != "" ? "/${local.stage}" : ""}"
    region = "${get_env("TF_STATE_S3_REGION")}"
    access_key = "${get_env("TF_STATE_S3_ACCESS_KEY")}"
    secret_key = "${get_env("TF_STATE_S3_SECRET_KEY")}"

    endpoints = {
      s3 = "${get_env("TF_STATE_S3_ENDPOINT")}"
    }

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
  }
}
EOF
}
