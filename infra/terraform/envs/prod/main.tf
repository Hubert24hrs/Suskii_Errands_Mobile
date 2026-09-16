# prod environment. State lives in the ops state bucket; pass it at init:
#   terraform init -backend-config="bucket=<state bucket>"
# Copy terraform.tfvars.example to terraform.tfvars (git-ignored) before plan.

terraform {
  required_version = ">= 1.9"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.3"
    }
  }
  backend "gcs" {
    prefix = "suskii/prod"
  }
}

provider "google" {
  project               = var.project_id
  region                = "europe-west2"
  user_project_override = true
  billing_project       = var.project_id
}

module "environment" {
  source = "../../modules/environment"

  environment             = "prod"
  project_id              = var.project_id
  github_deploy_condition = "assertion.ref == 'refs/heads/main' && (assertion.environment == 'production' || assertion.environment == 'infra-prod')"
  billing_account_id      = var.billing_account_id
  monthly_budget_usd      = var.monthly_budget_usd
  alert_emails            = var.alert_emails
  supabase_project_ref    = var.supabase_project_ref
  health_check_api_key    = var.health_check_api_key
  deploy_ai_service       = var.deploy_ai_service
  ai_service_image        = var.ai_service_image
}

output "workload_identity_provider" {
  value = module.environment.workload_identity_provider
}

output "deployer_service_account" {
  value = module.environment.deployer_service_account
}

output "terraform_service_account" {
  value = module.environment.terraform_service_account
}

output "artifact_registry" {
  value = module.environment.artifact_registry
}
