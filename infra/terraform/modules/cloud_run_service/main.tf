# A Cloud Run service with its own least-privilege identity, secrets mounted by reference,
# and traffic managed by the deploy pipeline (canary then 100%, infra-cicd.md §6.4).

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "name" {
  type = string
}

variable "image" {
  description = "Image reference by digest."
  type        = string
}

variable "environment" {
  type = string
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "min_instances" {
  type    = number
  default = 0
}

variable "max_instances" {
  type    = number
  default = 3
}

variable "cpu" {
  type    = string
  default = "1"
}

variable "memory" {
  type    = string
  default = "512Mi"
}

variable "env" {
  description = "Plain environment variables (never secrets)."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Environment variable name → Secret Manager secret id (latest version)."
  type        = map(string)
  default     = {}
}

resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "${var.name}-run"
  display_name = "${var.name} runtime (${var.environment})"
}

resource "google_secret_manager_secret_iam_member" "runtime_access" {
  for_each  = var.secret_env
  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_cloud_run_v2_service" "this" {
  project             = var.project_id
  name                = var.name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = var.environment == "prod"
  labels              = var.labels

  template {
    service_account = google_service_account.runtime.email

    scaling {
      min_instance_count = var.min_instances
      max_instance_count = var.max_instances
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
      }

      dynamic "env" {
        for_each = var.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }
    }
  }

  # The deploy pipeline shifts traffic between revisions; Terraform must not undo a canary.
  lifecycle {
    ignore_changes = [traffic, template[0].containers[0].image]
  }

  depends_on = [google_secret_manager_secret_iam_member.runtime_access]
}

output "uri" {
  value = google_cloud_run_v2_service.this.uri
}

output "service_account" {
  value = google_service_account.runtime.email
}
