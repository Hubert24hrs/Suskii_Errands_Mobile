# RB-13 — A feature must be switched off now, or users forced onto a new app version

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | Used inside SEV1–SEV3 incidents (RB-01) |
| Last rehearsed | Not yet — rehearse each switch below on staging before launch |
| Related | ERD §1 (`feature_flags`, `remote_config`); `get_bootstrap()`; PRD SH-35, AD-22; ai-design §6.5; RB-01, RB-10, RB-14 |

## How the switches work

| Mechanism | Table | Reaches clients through | Takes effect |
|---|---|---|---|
| **Feature flag** (on/off, % rollout, per country) | `public.feature_flags` (`key`, `country_code` NULL = global, `enabled`, `rollout_pct`, `client_visible`) | `get_bootstrap()` → `feature_flags` | On the app's **next bootstrap** (cold start or resume refresh — Kimi's app decides when it re-fetches). Server-side checks that read the flag take effect immediately |
| **Remote config** (values) | `public.remote_config` (`key`, `country_code`, `value`, `client_visible`) | `get_bootstrap()` → `remote_config`, `min_supported_app_version` | Same |
| **Forced update** | `remote_config` key `min_supported_app_version` = `{"android": "x.y.z", "ios": "x.y.z", "web": "x.y.z"}` | Bootstrap → blocking update screen (PRD SH-35) | Next bootstrap |
| **Country off** | `public.countries.status` | Bootstrap countries list; Before User Created Hook refuses phone sign-ups for non-live/beta countries | Immediately for sign-ups; next bootstrap for apps |

A country row overrides the global row for the same key. Every change to these tables is written to the hash-chained `audit.log` by trigger, with the before and after values.

**Important limit:** a client flag only hides or disables a feature in the app. For anything involving money, safety or data exposure, the server must also refuse the action. Flags checked server-side are listed per feature as those features are built (Phases 3–7); until then, treat a client flag as a UX switch, not a security control.

## Known switches

| Key | Type | Effect when off | Used for |
|---|---|---|---|
| `concierge.text` | flag | Concierge hidden; request form only (ai-design §6.5) | AI outage, cost runaway, harmful output |
| `concierge.voice` | flag | Voice entry hidden; text concierge remains | Voice vendor outage, cost |
| `voice_languages` | remote config `{"en": true, "pcm": false}` | Per-language voice availability (OD-17) | Pidgin voice gate |
| `calls.pstn_fallback` | flag | No masked phone-call fallback | Telephony vendor problems or cost |
| `min_supported_app_version` | remote config | Blocks versions below it | Broken or insecure app release |
| `ops.outbox_max_age_seconds` | remote config (server only) | Health outbox check skipped when absent | Health tuning |

Add a row here whenever a feature ships with a new switch. Features in Phases 3–7 (payments per method, payouts, referrals, promos, SOS partner dispatch) each get one before launch.

## Symptoms

- A feature causing harm or cost: wrong prices shown, abusive AI output, payment method failing, SMS pumping, vendor outage.
- An app release crashing or insecure (crash-free sessions below 99.5%, a security finding).
- A country must stop taking new users (regulator, partner or legal instruction).

## Immediate actions

1. Open or join the incident (RB-01). Name the switch you are about to flip in the incident channel **before** flipping it.
2. Flip it using the SQL below in the Supabase SQL editor for the right project (production changes need the IC's go-ahead). Until the admin dashboard exists (PRD AD-22, four-eyes), this is the only path.
3. Verify with `get_bootstrap()` as below, then on a real device after a cold start.
4. Note the time; the app's next bootstrap is when users see it.

**Stop conditions:**
- Never flip a switch in the wrong project: check the project ref in the dashboard URL against the incident.
- Never delete a flag or config row to "turn it off": set `enabled = false` so the audit trail shows the change and it can be reversed.
- Never raise `min_supported_app_version` above a version that is actually available in both stores; users would be locked out with nothing to update to.
- Never use a client flag as the only protection for money or personal data (see the limit above).

## Resolution — exact commands

Turn a feature off globally:

```sql
UPDATE public.feature_flags
SET enabled = false
WHERE key = 'concierge.voice' AND country_code IS NULL;
```

Turn it off for one country (creates the override row if missing):

```sql
INSERT INTO public.feature_flags (key, country_code, enabled, rollout_pct, client_visible)
VALUES ('concierge.voice', 'NG', false, 100, true)
ON CONFLICT (key, country_code) DO UPDATE SET enabled = EXCLUDED.enabled;
```

Roll out gradually (users are bucketed stably by user id; anonymous users only see fully rolled-out flags):

```sql
UPDATE public.feature_flags SET enabled = true, rollout_pct = 10
WHERE key = 'concierge.voice' AND country_code IS NULL;
```

Force an app update:

```sql
UPDATE public.remote_config
SET value = '{"android": "1.4.2", "ios": "1.4.2", "web": "1.4.2"}'
WHERE key = 'min_supported_app_version' AND country_code IS NULL;
```

Stop new users in a country (existing users and in-flight jobs continue):

```sql
UPDATE public.countries SET status = 'disabled' WHERE code = 'KE';
```

Changing a country's status is also a four-eyes action once the admin dashboard exists (PRD AD-22). In an emergency before then, record the second person's approval in the incident log.

Verify:

```sql
SELECT public.get_bootstrap('NG', 'android') -> 'feature_flags';
SELECT public.get_bootstrap('NG', 'android') ->> 'min_supported_app_version';
SELECT action, target_id, before, after, created_at
FROM audit.log WHERE target_table IN ('public.feature_flags', 'public.remote_config', 'public.countries')
ORDER BY id DESC LIMIT 5;
```

Expected: the flag shows the new value, and an audit row records the change.

## Backout

Run the same statement with the previous value (take it from the audit row's `before`). For a forced update, lowering the minimum version immediately unblocks users on their next bootstrap.

## Communication

- Support gets a one-line script whenever a user-visible feature is switched off.
- A forced update or a country switched off needs client approval and a user-facing message (RB-01 comms).
- Tell Kimi Code in `HANDOFF.md` when a new switch is added or a switch's meaning changes.

## After the incident

- Decide whether the switch stays off, and record why in the incident write-up.
- If a switch was missing when needed, adding it is a follow-up task.
