# infra/terraform — GCP for Suskii

Owner: Claude Code. Design: [infra-cicd.md](../../docs/plan/infra-cicd.md) §1, §3, §4, §7, §8, §9. CI: `.github/workflows/infra.yaml` (fmt, validate against the provider schemas, tflint).

**Nothing here has been applied.** It needs the client's GCP organisation, projects and an open billing account (timeline client actions 1 and 8).

## Layout

| Path | What |
|---|---|
| `bootstrap/` | One-time, local state: the Terraform state bucket in the `suskii-ops` project |
| `modules/environment/` | Everything one environment needs on GCP (below). Every env root calls it, so dev, staging and prod cannot drift in shape |
| `modules/cloud_run_service/` | A Cloud Run service with its own runtime identity and secrets by reference; traffic and image left to the deploy pipeline |
| `envs/{dev,staging,prod}/` | Thin roots: backend prefix, the GitHub deploy condition, budgets |

## What `modules/environment` creates

| Area | Resources | Plan reference |
|---|---|---|
| APIs | Run, Artifact Registry, Secret Manager, BigQuery, Monitoring, Logging, IAM, STS, Play Integrity, Billing Budgets | §3 |
| Keyless deploys | Workload Identity pool + GitHub OIDC provider restricted to this repository **and** `main` (dev, staging) or the protected `production` GitHub environment (prod); a `github-deployer` service account | §4 |
| Images | Artifact Registry repository `suskii` (Docker) — prod receives the digests that passed staging | §6.1 |
| Secrets | Secret Manager **names only**, replicated in `europe-west2`; values are added out of band and rotated per RB-10 | §4 |
| Analytics | BigQuery datasets `analytics`, `ai_evals`, `ops` in the EU multi-region | OD-15, ai-design §10 |
| Backups | Versioned EU bucket, public access blocked, retention policy (35 days minimum), Coldline after 30 days; a `backup-worker` identity that can only create objects | §8 |
| Alerting | Email notification channels; monthly budget alerts at 50/80/100% (when the billing account is set); an uptime check on the Supabase `health` function every 60 s with the API key header masked, and an alert policy when it fails | §7, §9 |
| AI service | Cloud Run service, only when `deploy_ai_service = true` (Phase 7) | C4 |

## Usage

```bash
# once
terraform -chdir=bootstrap init
terraform -chdir=bootstrap apply -var ops_project_id=suskii-ops -var state_bucket_name=<name> -var 'state_admins=["user:..."]'

# per environment
cp envs/dev/terraform.tfvars.example envs/dev/terraform.tfvars   # git-ignored
export TF_VAR_health_check_api_key=...                           # the Supabase "monitoring" secret key
terraform -chdir=envs/dev init -backend-config="bucket=<state bucket>"
terraform -chdir=envs/dev plan
```

## Deliberately not here yet

| Item | Why | When |
|---|---|---|
| Supabase projects and settings | Created by the client's Supabase organisation; schema and functions deploy through the Supabase CLI; auth settings live in `supabase/config.toml` | Phase 2 deploy pipeline |
| Cloudflare (DNS, WAF, Access for admin, Turnstile) | No domain yet and web hosting is undecided (infra-cicd I-2); Cloudflare provider v5 renamed resources, so it is written against the version in use when it lands | After I-2 |
| Sentry projects and alert rules | Community provider; set up with the client's Sentry organisation | With the first deployed environment |
| Log drains from Supabase | Plan-dependent (infra-cicd I-3) | After the Supabase plan is chosen |
