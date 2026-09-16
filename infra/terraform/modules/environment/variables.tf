variable "environment" {
  description = "dev, staging or prod."
  type        = string
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "project_id" {
  description = "GCP project for this environment (created by the client under the Suskii organisation)."
  type        = string
}

variable "region" {
  description = "Co-located with the Supabase project (ADR-0008: London, provisional)."
  type        = string
  default     = "europe-west2"
}

variable "github_repository" {
  description = "owner/name of the repository allowed to deploy through Workload Identity Federation."
  type        = string
  default     = "Hubert24hrs/Suskii_Errands_Mobile"
}

variable "github_deploy_condition" {
  description = "Extra CEL condition on the GitHub OIDC token, e.g. restricting prod to the production environment."
  type        = string
}

variable "billing_account_id" {
  description = "Billing account for the budget alert. Null skips the budget (e.g. before billing is open)."
  type        = string
  default     = null
}

variable "monthly_budget_usd" {
  description = "Monthly GCP budget; alerts at 50, 80 and 100 percent (infra-cicd.md §9)."
  type        = number
}

variable "alert_emails" {
  description = "On-call email addresses for uptime and budget alerts (RB-01)."
  type        = list(string)
}

variable "supabase_project_ref" {
  description = "Supabase project ref. Null skips uptime monitoring until the project exists."
  type        = string
  default     = null
}

variable "health_check_api_key" {
  description = "Named Supabase secret key \"monitoring\" sent to the health function. Stored in state: the state bucket is access-restricted."
  type        = string
  default     = null
  sensitive   = true
}

variable "runtime_secret_ids" {
  description = "Secret Manager secret ids to create (values are added out of band, never in Terraform)."
  type        = list(string)
  default = [
    "send-sms-hook-secrets",
    "google-play-integrity-service-account",
    "sentry-dsn-edge-functions",
    "sentry-dsn-ai-service",
    "supabase-service-role-key",
    "supabase-db-password",
    "supabase-db-backup-url",
    "supabase-storage-sync-key",
  ]
}

variable "backup_retention_days" {
  description = "Minimum retention for logical backups (infra-cicd.md §8)."
  type        = number
  default     = 35
}

variable "deploy_ai_service" {
  description = "Create the AI service on Cloud Run. False until Phase 7 publishes an image."
  type        = bool
  default     = false
}

variable "ai_service_image" {
  description = "Image digest for the AI service, promoted from staging (infra-cicd.md §6)."
  type        = string
  default     = null
}

variable "labels" {
  description = "Extra labels for every labelled resource."
  type        = map(string)
  default     = {}
}

variable "backup_worker_image" {
  description = "Image digest of services/workers. Null keeps the backup jobs uncreated."
  type        = string
  default     = null
}

variable "backup_delete_after_days" {
  description = "Backups older than this are deleted by lifecycle rule; must exceed backup_retention_days."
  type        = number
  default     = 120
  validation {
    condition     = var.backup_delete_after_days > var.backup_retention_days
    error_message = "backup_delete_after_days must be greater than backup_retention_days."
  }
}

variable "backup_dump_schedule" {
  description = "Cron (UTC) for the nightly dump."
  type        = string
  default     = "15 2 * * *"
}

variable "backup_verify_schedule" {
  description = "Cron (UTC) for the restore verification, after the dump has finished."
  type        = string
  default     = "15 4 * * *"
}

variable "backup_storage_sync_schedule" {
  description = "Cron (UTC) for mirroring Supabase Storage buckets."
  type        = string
  default     = "15 3 * * *"
}

variable "storage_sync_buckets" {
  description = "Supabase Storage bucket ids to mirror. kyc-docs goes to its own bucket."
  type        = list(string)
  default     = ["avatars", "request-media", "chat-media", "proofs", "receipts", "kyc-docs"]
}
