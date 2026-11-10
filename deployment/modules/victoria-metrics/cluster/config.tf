terraform {
  required_version = "~> 1.10"

  required_providers {
    onepassword = {
      source  = "1Password/onepassword"
      version = "~> 3.3"
    }
    infisical = {
      source  = "infisical/infisical"
      version = "~> 0.20"
    }
  }
}
