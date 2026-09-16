# ADR-0005 — Smile ID as the primary identity verification vendor

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-16 |
| Deciders | Claude Code (recommendation), client (contract) |
| Unblocked by | Spike S-05 (SDK version on 2 GB devices), signed vendor contract, OD-13 |

## Context

Both customers and providers complete facial verification, and every provider completes full KYC. The spec names Smile ID as the primary candidate and requires us to verify coverage, SDKs, liveness certification and pricing.

Phase 0 found: government-authority-backed verification in Côte d'Ivoire, Ghana, Kenya, Nigeria, South Africa, Uganda, Zambia and Zimbabwe, covering all wave-1 countries [S]; Enhanced SmartSelfie passed a Fime ISO/IEC 30107-3 Level 2 presentation-attack evaluation in Jan 2025 [S] (Fime, not iBeta, so ask for the letter); Smile Secure does 1:N duplicate-face search within our own tenant [S]; a healthy Flutter SDK (`smile_id` 11.2.13) plus a brand-new v12 (`usesmileid` 12.1.1) with on-device ML, and a web SDK (`@smileid/web-sdk` 12.0.4) that makes web facial verification feasible [V]. Pricing is sales-quoted [S]. Alternatives (Youverify, Dojah, QoreID, Prembly) are Nigeria-weighted, and their Flutter SDKs have thin adoption [V].

## Decision

We will make Smile ID the primary implementation of `IdentityVerificationProvider` for all wave-1 countries, with a Nigerian server-side fallback (Youverify or Dojah) for NIN/BVN lookups when Smile ID is unavailable. The Flutter SDK version is chosen by spike S-05. Our database stores only job IDs, result codes, reference IDs and reviewer decisions; biometric templates stay vendor-side. Verification failures never auto-approve: they queue for a Verification Officer.

## Consequences

**Good:** one vendor covers all five countries for both customer and provider flows, on mobile and web; duplicate-face detection supports the ban-evasion requirement.

**Bad / costs:** KYC is the largest variable cost in the model (~$87k/month at 1M MAU) and the vendor price for repeat selfie authentication drives OD-13; vendor lock-in on templates needs a deletion SLA in the contract.

**Follow-on work:** contract asks listed in the vendor matrix (PAD letter, Smile Secure scope, authentication unit price, data location, deletion SLA); adapter interface in contracts v1; outage queueing behaviour.

## Alternatives considered

| Option | Why not |
|---|---|
| Youverify / Dojah / QoreID as primary | Nigeria-weighted coverage; would need a second vendor for KE/GH/ZA/UG anyway |
| Veriff / Onfido / Persona | Strong globally, weaker on African government-ID lookups; reconsider for the global phase |
| Build liveness in-house | No PAD certification, no ID-authority access; unacceptable fraud and compliance risk |

## Revisit when

S-05 shows the SDK is unusable on 2 GB devices, pricing lands above the cost model, a wave-1 country loses coverage, or expansion moves outside Smile ID territory.
