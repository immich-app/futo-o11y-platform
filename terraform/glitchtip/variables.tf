variable "env" {}

# The Infisical environment slug of var.env (ENVIRONMENT_SHORT from mise).
variable "env_short" {}

variable "ovh_application_key" {
  sensitive = true
}
variable "ovh_application_secret" {
  sensitive = true
}
variable "ovh_consumer_key" {
  sensitive = true
}
