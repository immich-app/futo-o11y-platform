variable "netbird_tf_pat" {
  sensitive = true
}

variable "env" {}

variable "op_connect_host" {
  type    = string
  default = "https://opc.o11y.futo.network"
}

variable "op_connect_token_write" {
  type      = string
  sensitive = true
}

# Matches the env's private_network_cidr from the ovh module — the vRack subnet
# the Talos nodes advertise as a NetBird network route for operator access.
variable "private_network_cidr" {
  type = string
}
