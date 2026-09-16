output "workload_identity_provider" {
  description = "Value for google-github-actions/auth `workload_identity_provider`."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "deployer_service_account" {
  description = "Value for google-github-actions/auth `service_account`."
  value       = google_service_account.deployer.email
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "backup_bucket" {
  value = google_storage_bucket.backups.name
}

output "secret_ids" {
  value = [for s in google_secret_manager_secret.runtime : s.secret_id]
}
