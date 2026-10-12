terraform {
  required_version = ">= 1.9"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.10"
    }
  }

  # Partial backend config: storage account / container / key are passed with
  # -backend-config at `terraform init` time (see scripts/bootstrap.sh and the workflows).
  backend "azurerm" {
    use_oidc         = true
    use_azuread_auth = true
  }
}

# Auth comes from the environment: ARM_USE_OIDC / ARM_CLIENT_ID / ARM_TENANT_ID /
# ARM_SUBSCRIPTION_ID in CI (no stored secrets), or `az login` locally.
provider "azurerm" {
  features {}
  storage_use_azuread = true
}
