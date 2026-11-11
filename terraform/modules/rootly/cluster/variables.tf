variable "env" {}

variable "rootly_api_token" {
  type      = string
  sensitive = true
}

variable "rootly_zulip_webhook" {
  type      = string
  sensitive = true
}
