-- Nigeria's terms of service and privacy policy, as published on suskiierrand.com (owner,
-- 2026-11-21, OD-34: publish the draft now, counsel reviews afterwards). These were the last two
-- go-live gaps a production database had for Nigeria once ADR-0025 removed the payment, payout and
-- SMS ones. The privacy policy has been live since 2026-10-25; the terms page ships with the
-- web-marketing change of the same day and must be deployed before Nigeria goes live.
--
-- A database that was seeded (dev, staging, the testers' sandbox) already holds version 1 of both
-- with placeholder `.invalid` URLs; those rows take the real URL. A row with a real URL is never
-- touched, so a later version or a corrected URL is not undone by a replay.

INSERT INTO public.legal_documents (country_code, type, version, locale, url, published_at) VALUES
  ('NG', 'terms',   1, 'en', 'https://suskiierrand.com/en/legal/terms',   now()),
  ('NG', 'privacy', 1, 'en', 'https://suskiierrand.com/en/legal/privacy', now())
ON CONFLICT (country_code, type, version, locale) DO UPDATE
  SET url = EXCLUDED.url,
      published_at = coalesce(public.legal_documents.published_at, EXCLUDED.published_at)
  WHERE public.legal_documents.url LIKE '%.invalid%';
