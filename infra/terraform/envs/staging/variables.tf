variable "project_id" {
  type = string
}

variable "billing_account_id" {
  type    = string
  default = null
}

variable "monthly_budget_usd" {
  type    = number
  default = 300
}

variable "alert_emails" {
  type = list(string)
}

variable "supabase_project_ref" {
  type    = string
  default = null
}

variable "health_check_api_key" {
  type      = string
  default   = null
  sensitive = true
}

variable "deploy_ai_service" {
  type    = bool
  default = false
}

variable "ai_service_image" {
  type    = string
  default = null
}
