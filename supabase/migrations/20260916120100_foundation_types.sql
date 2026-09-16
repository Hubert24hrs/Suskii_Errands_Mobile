-- Enum types shared across the platform. Values are the snake_case wire format that
-- Kimi Code's Dart enums map with @JsonValue (review N.6), so these names are a contract
-- surface: adding a value is additive; renaming or removing one is a breaking change.

CREATE TYPE public.user_mode AS ENUM ('customer', 'provider');

CREATE TYPE public.country_status AS ENUM ('disabled', 'beta', 'live');

CREATE TYPE public.urgency AS ENUM ('flexible', 'standard', 'urgent', 'emergency');

CREATE TYPE public.trust_level AS ENUM ('new', 'verified', 'trusted', 'elite');

CREATE TYPE public.vehicle_type AS ENUM
  ('walking', 'bicycle', 'motorcycle', 'tricycle', 'car', 'van', 'truck');

CREATE TYPE public.verification_status AS ENUM
  ('unverified', 'pending', 'in_review', 'verified', 'rejected', 'suspended', 'expired');

-- The 20 job lifecycle states (docs/plan/state-machines/job-lifecycle.md).
CREATE TYPE public.job_status AS ENUM (
  'draft', 'published', 'offers_received', 'negotiating', 'agreed',
  'payment_pending', 'paid_held', 'assigned', 'en_route', 'arrived',
  'in_progress', 'completed_by_provider', 'confirmed', 'settlement_pending', 'settled',
  'closed', 'cancelled', 'expired', 'disputed', 'refunded'
);

CREATE TYPE public.offer_status AS ENUM
  ('pending', 'countered', 'accepted', 'declined', 'expired', 'withdrawn');

CREATE TYPE public.payment_status AS ENUM
  ('unpaid', 'pending', 'held', 'failed', 'refunded', 'partially_refunded');

CREATE TYPE public.referral_commission_status AS ENUM
  ('pending', 'earned', 'holding', 'available', 'reversed');

CREATE TYPE public.chat_message_type AS ENUM
  ('text', 'image', 'voice_note', 'location', 'offer_card', 'system');

CREATE TYPE public.provider_kind AS ENUM ('individual', 'business');

CREATE TYPE public.business_role AS ENUM ('owner', 'dispatcher', 'worker');

CREATE TYPE public.kyc_step_kind AS ENUM (
  'customer_facial', 'government_id', 'provider_facial', 'id_document_capture',
  'police_clearance', 'address', 'guarantor', 'payout_account', 'vehicle_documents',
  'credentials'
);

CREATE TYPE public.kyc_step_status AS ENUM
  ('not_started', 'consent_pending', 'in_progress', 'in_review', 'verified', 'rejected', 'expired');

CREATE TYPE public.identity_check_outcome AS ENUM ('success', 'retry', 'failed');

CREATE TYPE public.consent_kind AS ENUM
  ('biometric', 'criminal_record_check', 'location', 'marketing', 'voice_processing');

CREATE TYPE public.admin_role AS ENUM
  ('super_admin', 'verification_officer', 'support_agent', 'finance_officer', 'dispute_officer');

CREATE TYPE public.device_platform AS ENUM ('android', 'ios', 'web');
