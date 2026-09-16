# Architecture — C4 views

| | |
|---|---|
| Owner | Claude Code |
| Date | 2026-09-16 |
| Status | Phase 1 draft |
| Evidence | Spec `architecture`; Phase 0 REPORT §6, §9, §10; ADR-0002, 0006, 0008, 0009, 0011, [0012](../adr/0012-ai-tools-act-as-user.md) |
| Companions | [threat-model.md](threat-model.md) (uses these component boundaries), [data-flow.md](data-flow.md) (uses these trust boundaries) |

Three levels: who uses the system and what it depends on (context), the deployable pieces (containers), and the inside of the backend (components). Diagrams are Mermaid flowcharts rather than Mermaid's experimental C4 syntax, because flowcharts render reliably on GitHub.

## Level 1 — System context

```mermaid
flowchart LR
    subgraph People
        CU([Customer])
        PR([Provider / worker])
        BO([Business owner / dispatcher])
        ST([Staff: 5 admin roles])
        TC([Trusted contact])
    end

    SUS[[Suskii Errands platform]]

    subgraph Money
        FW[Flutterwave]
        PS[Paystack]
        SP[Stripe — global phase]
    end
    subgraph Identity
        SID[Smile ID]
        NGF[Youverify / Dojah — NG fallback]
    end
    subgraph Communication
        LK[LiveKit Cloud]
        SMS[Termii / Africa's Talking — SMS OTP]
        TEL[Infobip / Africa's Talking — masked PSTN]
        PUSH[FCM / APNs]
        MAIL[Email — SES]
    end
    subgraph Intelligence
        VX[Vertex AI — Gemini]
        MAPS[Google Maps Platform]
    end
    subgraph Safety
        SOS[AURA / Rescue.co / NG dispatch partner]
    end
    subgraph Operations
        OBS[Sentry / PostHog]
        CF[Cloudflare]
    end

    CU -- requests, negotiates, pays, tracks --> SUS
    PR -- offers, works, gets paid --> SUS
    BO -- dispatches workers, fleet --> SUS
    ST -- verifies, supports, resolves, reconciles --> SUS
    TC -- views an expiring trip link --> SUS

    SUS -- hosted checkout, transfers, webhooks --> FW & PS & SP
    SUS -- liveness, ID lookup, dedupe --> SID & NGF
    SUS -- rooms, tokens, voice agent --> LK
    SUS -- OTP --> SMS
    SUS -- proxy numbers --> TEL
    SUS -- notifications, VoIP push --> PUSH & MAIL
    SUS -- concierge, moderation, embeddings --> VX
    SUS -- places, maps --> MAPS
    SUS -- dispatch incident --> SOS
    SUS -- errors, product analytics --> OBS
    CF -- WAF, bot defence, CDN --> SUS
```

Wave-1 routing per country lives in the country packs (ADR-0001); Stripe carries no African traffic (OD-11).

## Level 2 — Containers

```mermaid
flowchart TB
    subgraph Clients["Clients — untrusted"]
        MOB["Flutter app<br/>Customer + Provider modes<br/>Android / iOS"]
        WEB["Next.js customer web app"]
        MKT["Next.js marketing site"]
        ADM["Next.js admin dashboard"]
    end

    CF["Cloudflare<br/>WAF · Turnstile · CDN · Access (admin)"]

    subgraph SB["Supabase project — EU region (London, provisional: ADR-0008)"]
        AUTH["Auth<br/>phone / email OTP, Google, Apple, TOTP MFA<br/>Send SMS Hook · Custom Access Token Hook"]
        API["Data API (PostgREST)<br/>RPC only for writes"]
        RT["Realtime<br/>private channels · Broadcast"]
        STO["Storage<br/>private buckets · signed URLs"]
        EF["Edge Functions (Deno)<br/>payments · webhooks · LiveKit tokens · push/VoIP<br/>integrity · SOS dispatch · PSTN · SMS hook"]
        PG[("Postgres<br/>public · private · ledger · kyc · audit<br/>PostGIS · pgvector · pgmq · pg_cron · pg_partman")]
        VAULT["Vault"]
    end

    subgraph GCP["Google Cloud — europe-west2 (with ADR-0008)"]
        AI["AI service — FastAPI on Cloud Run<br/>LLM gateway · concierge tools · matching · pricing<br/>moderation · receipts · admin assistant"]
        WRK["Workers — Cloud Run<br/>queue consumers · settlement · reconciliation<br/>reputation · price bands · exports"]
        BQ[("BigQuery<br/>pseudonymised analytics")]
        SM["Secret Manager"]
    end

    VOICE["Voice agent — LiveKit Agents (Python)<br/>hosted on LiveKit Cloud"]
    LKC["LiveKit Cloud<br/>rooms · SFU"]

    MOB & WEB --> CF
    ADM --> CF
    MKT --> CF
    CF --> AUTH & API & RT & STO & EF
    MOB & WEB -- "JWT" --> AI
    MOB & WEB -- "room token" --> LKC
    API --> PG
    RT --> PG
    EF --> PG
    AUTH --> PG
    AI -- "user's JWT, RLS applies (ADR-0012)" --> API
    AI --> VX[(Vertex AI Gemini)]
    WRK -- "pgmq consume · service role" --> PG
    PG -- "scheduled export" --> BQ
    VOICE --> LKC
    VOICE -- "user's JWT (ADR-0012)" --> AI
    EF -.-> VAULT
    AI & WRK -.-> SM
```

### Container responsibilities

| Container | Owns | Does **not** own |
|---|---|---|
| **Flutter app / web apps** | Rendering server state; collecting input; device signals (integrity tokens, RASP, mock-location flags); broadcasting live location during a job | Any price, fee, payout, status or verification decision |
| **Cloudflare** | WAF, bot management, rate limiting at the edge, Turnstile CAPTCHA, CDN for marketing; **Cloudflare Access (zero trust) in front of the admin dashboard** | Authorisation — that is always the database |
| **Supabase Auth** | Sessions, OTP (via the Send SMS Hook to regional SMS providers), social login, TOTP MFA; the Custom Access Token Hook adds `admin_roles` and mode claims | Trusting its own claims for sensitive data — functions re-check the database (RLS matrix) |
| **Data API** | Reads under RLS; **writes only through RPC functions** for anything in the RLS matrix marked F | Direct writes to state, money or verification columns |
| **Realtime** | Private channels authorised by RLS on `realtime.messages`; Broadcast for live location (ADR-0009) | Persistence — sampled location goes to `location_samples` via RPC |
| **Storage** | Private buckets, signed upload/download URLs, size and type limits | Serving KYC documents to anyone but audited officers |
| **Edge Functions** | Synchronous HTTP work: payment initialisation, webhook intake (verify, store raw, de-duplicate), LiveKit token minting, push and VoIP sending, integrity-token verification, SOS partner dispatch, PSTN fallback, Send SMS Hook | Anything long-running. The limits are a 2 s CPU budget and a 400 s wall clock per request (REPORT §10) |
| **Postgres** | The source of truth: state machines, ledger, RLS, outbox, queues (pgmq), schedules (pg_cron), partitions | Calling third parties itself |
| **AI service** | The LLM gateway (model routing from remote config, ADR-0006), concierge tools, matching score, price bands, moderation, receipt reading, admin assistant | Moving money, approving verification, setting prices, resolving disputes (spec guardrails) |
| **Workers** | pgmq consumers: notifications fan-out, settlement and payouts, referral accrual, reconciliation, reputation recompute, price-band training export | Serving user requests |
| **Voice agent** | Real-time voice concierge (Gemini Live, or the cascade per OD-17) | Anything the text concierge may not do — it calls the same tools |
| **BigQuery** | Analytics and model training on pseudonymised exports | Operational reads |

## Level 3 — Backend components

```mermaid
flowchart TB
    subgraph PGC["Postgres — inside the database"]
        RPC["RPC surface<br/>(the contracts rpc-catalog)"]
        SM["State machine engine<br/>transition table · guards · FOR UPDATE · idempotency"]
        LED["Ledger posting functions<br/>validate → post → deferred zero-sum backstop (S-14)"]
        MATCH["Matching queries<br/>PostGIS on provider_live_location (S-06)"]
        EVT["job_events + outbox<br/>same transaction as the change"]
        Q["pgmq queues<br/>notify · settle · referral · ai_followup · analytics · moderation"]
        CRON["pg_cron schedules<br/>offer / request / payment expiry · auto-confirm · dispute window<br/>referral holds · document expiry · partitions · reconciliation"]
        RLS["RLS + column grants + helper functions<br/>(rls-policy-matrix.md)"]
    end

    RPC --> RLS
    RPC --> SM
    SM --> LED
    SM --> EVT
    RPC --> MATCH
    EVT -- dispatcher --> Q
    CRON --> SM

    subgraph EFC["Edge Functions"]
        PAY["payments-init"]
        WH["webhooks: gateway · KYC · telephony"]
        TOK["livekit-token"]
        PUSHF["push / VoIP sender"]
        INT["integrity-verify"]
        SOSF["sos-dispatch"]
        SMSH["send-sms-hook"]
    end

    subgraph WK["Workers (Cloud Run)"]
        NOTIF["notifications consumer"]
        SETTLE["settlement + payouts consumer"]
        RECON["reconciliation job"]
        REP["reputation + price bands"]
    end

    WH -- "verified event" --> SM
    PAY --> SM
    Q --> NOTIF --> PUSHF
    Q --> SETTLE --> LED
    CRON --> RECON --> LED
    Q --> REP
```

### Decisions this view fixes

| # | Decision | Why |
|---|---|---|
| 1 | **Writes are RPC functions, never table writes**, for everything state- or money-bearing | Spec backend rule 1; S-13 showed column grants plus functions are what actually hold |
| 2 | **Every state change writes `job_events` + `outbox` in the same transaction**; a dispatcher moves outbox rows to pgmq | Side effects (notifications, settlement, referral) can never fire for a transition that rolled back, and never get lost for one that committed |
| 3 | **Timeouts are pg_cron jobs calling the same state-machine functions** a user would | One code path per transition; a scheduled expiry obeys the same guards and emits the same events |
| 4 | **Edge Functions do synchronous HTTP; Cloud Run workers consume queues** | Edge Function CPU and wall-clock limits rule out long-running consumers |
| 5 | **Webhooks only ever call the state machine after verification** — signature, raw storage, de-duplication, then a server-side verify call to the gateway | The only path into `PAID_HELD` (job lifecycle #8) |
| 6 | **The AI service and voice agent act with the end user's JWT, not the service role** | Tools inherit RLS: a prompt-injected concierge still cannot touch another user's data. [ADR-0012](../adr/0012-ai-tools-act-as-user.md) |
| 7 | **Clients reach the AI service directly with their JWT**, which the service verifies against Supabase's JWKS | Avoids an extra hop through an Edge Function on a latency-sensitive path (~150 ms RTT, S-01) |
| 8 | **Card data never touches our infrastructure**; payment is a hosted checkout opened from the app | PCI DSS scope minimisation (SAQ-A target); ADR-0010 rejects the native Flutterwave SDK anyway |

## Deployment and regions

| Piece | Region | Basis |
|---|---|---|
| Supabase (dev, staging, prod as separate projects) | EU, London provisional | ADR-0008, pending S-01 |
| Cloud Run AI service + workers | `europe-west2` (London) — co-located with the database | Round trips between them must be intra-region |
| Vertex AI | `europe-west2` if the chosen models are served there; otherwise the nearest EU region | S-07 blocked on billing — availability unverified [A] |
| BigQuery | EU multi-region | Residency (OD-15) |
| LiveKit Cloud | Region-pinned to EU where possible; African edge quality unverified | S-01 [A] |
| Cloudflare | Global edge | — |

Separate Supabase projects per environment and migrations only through the Supabase CLI (spec). No seed data in production.

## Scale-out path (spec: document before launch)

| Pressure | First move | Next move |
|---|---|---|
| Nearest-provider query | Movement-gated heartbeats, fillfactor, autovacuum tuning (S-06: ~8–10× headroom at 1M MAU write rate) | Move `provider_live_location` to a dedicated service or Redis-geo only if dead-tuple churn outpaces autovacuum |
| Realtime connections (>10k peak) | Enterprise quota (cost model: ~60k at 1M MAU) | Self-hosted Realtime cluster |
| Read load | Read replica for the AI Admin Assistant and analytics reads | Geo-routed replicas |
| Write load on messages/events | Monthly partitions already in the ERD | Move chat to a dedicated service |
| Cross-region latency | Measure (S-01) | Self-hosted Supabase in Africa, costed as the OD-15 fallback |
