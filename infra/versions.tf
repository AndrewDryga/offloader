terraform {
  required_version = ">= 1.6"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }

  # Terraform Cloud, VCS-driven. Set the workspace's working directory to `infra/`, and
  # fill in your TFC org below. Remove this block to run with a local/other backend.
  cloud {
    organization = "REPLACE_WITH_YOUR_TFC_ORG"

    workspaces {
      name = "offloader-infra"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
}
