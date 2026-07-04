terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Terraform Cloud, VCS-driven. The workspace's working directory must be `infra/`.
  # Remove this block to run with a local/other backend.
  cloud {
    organization = "Dryga"

    workspaces {
      name = "offloader"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
}
