# Country pack drafts (Phase 0)

These are **research drafts** of the per-country configuration from `master_spec.country_packs`. They are YAML documents for review, **not** seed data or migrations. In Phase 1 they become the reviewed source for the `country_packs` table design, and in Phase 2 dev/staging seed data.

| File | Country | Proposed status |
|---|---|---|
| [NG.yaml](NG.yaml) | Nigeria | `live` candidate (reference pack, OD-07) |
| [KE.yaml](KE.yaml) | Kenya | `beta` |
| [GH.yaml](GH.yaml) | Ghana | `beta` |
| [ZA.yaml](ZA.yaml) | South Africa | `beta` (blocked on POPIA prior authorisation and TPPP) |
| [UG.yaml](UG.yaml) | Uganda | `beta` (single payment vendor) |

## Conventions

- **Money** is always integer minor units + ISO 4217 code. `minor_unit_exponent` comes from ISO 4217. **UGX has exponent 0**, so `min_withdrawal_minor: 5000` means USh 5,000.
- **Rates** are decimal strings (`"0.125"`) so they are never parsed as floats by accident.
- **Every field carries a status.** The `_status` map at the end of each file gives one of:

| Status | Meaning |
|---|---|
| `verified` | Confirmed against a primary source in Phase 0 (see REPORT.md) |
| `secondary` | Secondary source; confirm before go-live |
| `assumption` | Default proposed by Claude Code; needs a vendor, counsel or client decision |
| `placeholder` | Must be calibrated with pilot data (guardrails, multipliers) |

- A country may go `live` only when every field is `verified` or explicitly accepted by the client in the go-live checklist ([compliance-checklist-and-dpia.md](../compliance-checklist-and-dpia.md#3-country-go-live-checklist)).
- Phone validation uses libphonenumber (server and client). The regexes here are indicative only.
- Open decisions referenced (OD-xx) are listed in [CHECKPOINT-PHASE-0.md](../CHECKPOINT-PHASE-0.md).

## Schema (draft)

```yaml
country_code: ISO 3166-1 alpha-2
status: disabled | beta | live
launch:
  cities: [{ code, name, zones: [{ code, name, vehicle_types_allowed[], notes }] }]
currency: { code, minor_unit_exponent }
commercial: { commission_rate, referral_rate, referral_max_duration_months, promo_referral_stacking }
tax: { vat_rate, vat_components[], platform_vat_collection_agent, withholding_on_referral_payouts, notes }
payments:
  collection_routing: [{ method, primary, fallback, notes }]
  enabled_methods[]
  fee_bearer_setting
  payout_rails: [{ rail, networks[], primary, fallback }]
  min_withdrawal_minor
  withdrawal_approval_thresholds_minor: { single_approver, second_approver }
  funds_holding_model
kyc:
  vendor_routing: { primary, fallback }
  customer: { accepted_id_types[], facial_verification }
  provider: { accepted_id_types[], police_clearance: { document_name, issuer, portal, fee_note, validity_months, accept_issued_within_months, revalidate_every_months, verification_channel }, address_verification, guarantor }
  business_registration_documents[]
vehicles: { types_allowed_default[], documents: { <vehicle_type>: [...] } }
phone: { e164_prefix, nsn_length, indicative_mobile_regex, otp_routing: { primary, fallback, whatsapp_otp } }
languages: { supported[], default }
legal: { documents: [{ type, version, url_placeholder, requires_acceptance }] }
data_protection: { law, regulator, registration, breach_notice_hours, residency, retention_days: {...} }
safety: { emergency_numbers: {...}, sos_partners: [{ city, partner, integration }] }
restricted: { prohibited_items[], prohibited_services[] }
pricing: { guardrails: [{ category, soft_min_minor, soft_max_minor, hard_max_minor }], urgency_multipliers: {...}, offer_ttl_seconds_default, max_counter_rounds }
_status: { <field path>: verified | secondary | assumption | placeholder }
```
