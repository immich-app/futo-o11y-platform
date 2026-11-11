terraform {
  required_version = "~> 1.10"

  required_providers {
    rootly = {
      source  = "rootlyhq/rootly"
      version = "~> 5.17"
    }
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.20"
    }
  }
}
