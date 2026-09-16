# One-time bootstrap in the `suskii-ops` project: the Terraform state bucket (infra-cicd.md §3).
# Run with local state by a named admin, then never again; every environment root keeps its
# state in this bucket under its own prefix.

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
  }
}

variable "ops_project_id" {
  type = string
}

variable "state_bucket_name" {
  type = string
}

variable "state_admins" {
  description = "Members allowed to read and write state besides the per-environment deployers, e.g. user:alice@example.com."
  type        = list(string)
}

provider "google" {
  project = var.ops_project_id
}

resource "google_storage_bucket" "tfstate" {
  name                        = var.state_bucket_name
  location                    = "EUROPE-WEST2"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
    }
    action {
      type = "Delete"
    }
  }
}

resource "google_storage_bucket_iam_member" "admins" {
  for_each = toset(var.state_admins)
  bucket   = google_storage_bucket.tfstate.name
  role     = "roles/storage.objectAdmin"
  member   = each.value
}

output "state_bucket" {
  value = google_storage_bucket.tfstate.name
}
