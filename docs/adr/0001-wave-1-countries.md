# ADR-0001 — Launch Nigeria first, with Kenya, Ghana, South Africa and Uganda in beta

| | |
|---|---|
| Status | Proposed |
| Date | 2026-09-16 |
| Deciders | Claude Code (recommendation), client (OD-14) |
| Unblocked by | Client decision OD-14; per-country go-live checklist |

## Context

The spec ships one release and switches countries on through country packs (OD-07 defaults to Nigeria first). Phase 0 checked which African countries we can actually serve end to end today: payments in and out, government-ID verification, a police-clearance route, an SOS partner, and a launch language.

Five countries clear that bar (`docs/research/REPORT.md` §2): Nigeria, Kenya, Ghana, South Africa and Uganda. All are Anglophone, which matches the English + Nigerian Pidgin launch languages. Flutterwave covers collections and payouts in all five [V]. Smile ID covers government-ID lookup in all five [S]. AURA (ZA, KE, GH) or Rescue.co (KE, UG) can answer SOS; Nigeria has no API partner yet.

Market timing favours Nigeria: Uber left Nigeria and Uganda on 2 Sep 2026 over unit economics, and incumbents charge 15–30% against our 12.5% [S].

## Decision

We will treat Nigeria as the reference country pack and the first `live` country. Kenya, Ghana, South Africa and Uganda ship as `beta` and flip to `live` one at a time as each passes the go-live checklist. Every other country stays `disabled`. Côte d'Ivoire, Egypt, Rwanda and Tanzania are the next wave and need a language (French, Arabic RTL, Swahili) before they are credible.

## Consequences

**Good:** one pack proves the model; per-country risk is contained; country behaviour stays data, not code.

**Bad / costs:** Uganda depends on Flutterwave alone (R-21). South Africa is blocked behind POPIA prior authorisation and PASA TPPP registration, so it may go live last despite being the easiest market technically.

**Follow-on work:** the five country packs in `docs/research/country-packs/` become seed data in Phase 2; the go-live checklist becomes an admin flow in Phase 8.

## Alternatives considered

| Option | Why not |
|---|---|
| Nigeria only at launch | The architecture must prove multi-country before we scale; a single pack hides assumptions |
| Add Egypt or Côte d'Ivoire to wave 1 | Needs Arabic (RTL) or French, which are not launch languages |
| All African countries at once | No pack can be verified at that rate, and every country carries its own licensing question |

## Revisit when

A wave-1 country fails its go-live checklist twice, a payment or KYC vendor loses coverage, or the client funds a non-English language earlier than V1.1.
