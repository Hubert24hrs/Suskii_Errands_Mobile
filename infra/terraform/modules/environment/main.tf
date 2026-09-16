# One Suskii environment on GCP (docs/plan/infra-cicd.md §1, §3, §4, §7, §8, §9).
# Supabase projects, Cloudflare and Sentry are managed outside this module; see ../../README.md.

locals {
  labels = merge({
    app         = "suskii"
    environment = var.environment
    managed_by  = "terraform"
  }, var.labels)

  apis = [
    "artifactregistry.googleapis.com",
    "bigquery.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "playintegrity.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "sts.googleapis.com",
    "storage.googleapis.com",
  ]
}

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# GitHub Actions deploys without keys: OIDC → Workload Identity Federation (§4).
# ---------------------------------------------------------------------------
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"
  depends_on                = [google_project_service.apis]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"         = "assertion.sub"
    "attribute.repository"   = "assertion.repository"
    "attribute.ref"          = "assertion.ref"
    "attribute.environment"  = "assertion.environment"
    "attribute.workflow_ref" = "assertion.job_workflow_ref"
  }

  # Only this repository, plus the per-environment restriction (main branch for dev and
  # staging, the protected "production" GitHub environment for prod).
  attribute_condition = "assertion.repository == '${var.github_repository}' && (${var.github_deploy_condition})"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "deployer" {
  project      = var.project_id
  account_id   = "github-deployer"
  display_name = "GitHub Actions deployer (${var.environment})"
}

resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/artifactregistry.writer",
    "roles/run.admin",
    "roles/secretmanager.secretAccessor",
    "roles/iam.serviceAccountUser",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# ---------------------------------------------------------------------------
# Container images, promoted by digest from staging to prod (§6.1).
# ---------------------------------------------------------------------------
resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = "suskii"
  format        = "DOCKER"
  labels        = local.labels
  depends_on    = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Secrets: names only. Values are added out of band and rotated per RB-10 (§4).
# ---------------------------------------------------------------------------
resource "google_secret_manager_secret" "runtime" {
  for_each  = toset(var.runtime_secret_ids)
  project   = var.project_id
  secret_id = each.value
  labels    = local.labels

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
  depends_on = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Analytics: EU datasets (OD-15 residency; ai-design.md §10).
# ---------------------------------------------------------------------------
resource "google_bigquery_dataset" "datasets" {
  for_each = {
    analytics = "Pseudonymised product and marketplace analytics exported from Supabase"
    ai_evals  = "AI evaluation runs and scores (ai-design.md §8)"
    ops       = "Cost, SLO and reconciliation reporting"
  }
  project                    = var.project_id
  dataset_id                 = each.key
  description                = each.value
  location                   = "EU"
  delete_contents_on_destroy = false
  labels                     = local.labels
  depends_on                 = [google_project_service.apis]
}

# ---------------------------------------------------------------------------
# Logical backups of the Supabase database and private buckets (§8).
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "backups" {
  project                     = var.project_id
  name                        = "${var.project_id}-backups"
  location                    = upper(var.region)
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = local.labels

  versioning {
    enabled = true
  }

  retention_policy {
    retention_period = var.backup_retention_days * 86400
    is_locked        = false
  }

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_service_account" "backup_worker" {
  project      = var.project_id
  account_id   = "backup-worker"
  display_name = "Nightly logical backup worker (${var.environment})"
}

resource "google_storage_bucket_iam_member" "backup_writer" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.backup_worker.email}"
}

# ---------------------------------------------------------------------------
# Alerting: notification channels, budget, uptime (§7, §9).
# ---------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  for_each     = toset(var.alert_emails)
  project      = var.project_id
  display_name = "On-call ${each.value}"
  type         = "email"
  labels = {
    email_address = each.value
  }
  depends_on = [google_project_service.apis]
}

resource "google_billing_budget" "monthly" {
  count           = var.billing_account_id == null ? 0 : 1
  billing_account = var.billing_account_id
  display_name    = "suskii-${var.environment}-monthly"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.monthly_budget_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = [0.5, 0.8, 1.0]
    content {
      threshold_percent = threshold_rules.value
    }
  }

  all_updates_rule {
    monitoring_notification_channels = [for c in google_monitoring_notification_channel.email : c.id]
  }
}

resource "google_monitoring_uptime_check_config" "supabase_health" {
  count        = var.supabase_project_ref == null ? 0 : 1
  project      = var.project_id
  display_name = "suskii-${var.environment}-health"
  timeout      = "10s"
  period       = "60s"

  http_check {
    path           = "/functions/v1/health"
    port           = 443
    use_ssl        = true
    validate_ssl   = true
    request_method = "GET"
    mask_headers   = true
    headers = {
      apikey = var.health_check_api_key
    }
    accepted_response_status_codes {
      status_class = "STATUS_CLASS_2XX"
    }
  }

  monitored_resource {
    type = "uptime_url"
    labels = {
      project_id = var.project_id
      host       = "${var.supabase_project_ref}.supabase.co"
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_monitoring_alert_policy" "health_failing" {
  count                 = var.supabase_project_ref == null ? 0 : 1
  project               = var.project_id
  display_name          = "suskii-${var.environment}: health check failing"
  combiner              = "OR"
  notification_channels = [for c in google_monitoring_notification_channel.email : c.id]

  conditions {
    display_name = "Health endpoint not passing from multiple regions"
    condition_threshold {
      filter          = "metric.type=\"monitoring.googleapis.com/uptime_check/check_passed\" AND metric.label.check_id=\"${google_monitoring_uptime_check_config.supabase_health[0].uptime_check_id}\" AND resource.type=\"uptime_url\""
      duration        = "180s"
      comparison      = "COMPARISON_GT"
      threshold_value = 1
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_NEXT_OLDER"
        cross_series_reducer = "REDUCE_COUNT_FALSE"
        group_by_fields      = ["resource.label.*"]
      }
    }
  }

  documentation {
    mime_type = "text/markdown"
    content   = "The Supabase health function is failing or unreachable. The response body lists which check failed (outbox, audit chain, audit partitions, scheduled jobs, database). Follow RB-01 (incident response)."
  }
}

# ---------------------------------------------------------------------------
# AI service (Phase 7). Created only once an image exists.
# ---------------------------------------------------------------------------
module "ai_service" {
  source = "../cloud_run_service"
  count  = var.deploy_ai_service ? 1 : 0

  project_id    = var.project_id
  region        = var.region
  name          = "ai-service"
  image         = var.ai_service_image
  environment   = var.environment
  labels        = local.labels
  min_instances = var.environment == "prod" ? 1 : 0
  max_instances = var.environment == "prod" ? 20 : 3
  secret_env = {
    SENTRY_DSN = google_secret_manager_secret.runtime["sentry-dsn-ai-service"].secret_id
  }
}
