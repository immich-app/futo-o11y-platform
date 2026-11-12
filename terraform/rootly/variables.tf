variable "env" {}

# The Infisical environment slug of var.env (ENVIRONMENT_SHORT from mise).
variable "env_short" {}

variable "rootly_api_token" {
  type      = string
  sensitive = true
}

variable "rootly_zulip_webhook" {
  type      = string
  sensitive = true
}
