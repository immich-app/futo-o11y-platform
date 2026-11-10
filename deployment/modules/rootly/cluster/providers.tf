provider "rootly" {
  api_token = var.rootly_api_token
}

provider "onepassword" {
  connect_url   = var.op_connect_host
  connect_token = var.op_connect_token_write
}

# Authenticates from the environment: INFISICAL_TOKEN from the CI OIDC login
# or the operator's `infisical login` session, via the mise tg wrapper.
provider "infisical" {
  host = "https://infisical.futo.network"
}
