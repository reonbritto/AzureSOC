terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Local state. The state file can contain sensitive values (VM password,
  # storage keys) — keep deploy/terraform.tfstate* out of version control.
  backend "local" {}
}

provider "azurerm" {
  # Authenticates via the active `az login` session — no service principal.
  subscription_id = var.subscription_id

  features {
    key_vault {
      # Allow `terraform destroy` to purge the Key Vault so re-applies don't
      # collide with a soft-deleted vault of the same name.
      purge_soft_delete_on_destroy = true
    }
    resource_group {
      # The honeynet RG should delete cleanly even if a stray resource lingers.
      prevent_deletion_if_contains_resources = false
    }
  }
}

provider "random" {}
