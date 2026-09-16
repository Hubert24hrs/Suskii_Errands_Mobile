# ADR-0010 — Client packages we will not adopt, and what to use instead

| | |
|---|---|
| Status | Accepted |
| Date | 2026-09-16 |
| Deciders | Claude Code (audit), Kimi Code (implementation) |
| Unblocked by | — |

## Context

The spec tells Kimi Code to check maintenance status, licence and platform support before adding a plugin, and tells Claude Code to audit client dependencies. Phase 0 pulled the pub.dev, npm and PyPI registries directly (2026-09-15 snapshot) and found four packages that should not enter the build, plus one with a commercial licence [V].

## Decision

We will not adopt these, and will use the stated replacement instead. The audit checks for them at every integration milestone.

| Rejected | Why | Use instead |
|---|---|---|
| `flutterwave_standard` 1.1.0 | No verified publisher; last release Apr 2025; it sits on the money path | Server creates a hosted checkout link; open it in a Chrome Custom Tab or `SFSafariViewController`. Keeps card entry out of our PCI scope |
| `app_device_integrity` 1.1.0 | Stale since Dec 2024; it gates payouts and KYC | A thin platform channel calling Play Integrity and App Attest directly, verified server-side |
| `background_locator_2` 2.0.6 | Abandoned (2023), no verified publisher | `flutter_foreground_task` + `geolocator`, pending spike S-04 |
| `prembly_identity_kyc` 0.0.6 | Tagged web-only, negligible adoption | Smile ID (ADR-0005); Prembly only as a server-side API if ever needed |

`flutter_background_geolocation` 5.7.0 is not rejected, but its release builds need a **paid licence** on both platforms, and v4 keys do not work on v5. It may only be adopted if spike S-04 shows the free combination cannot hold a tracking session on Transsion devices, and only with the licence cost approved by the client.

## Consequences

**Good:** no abandoned or unverified code on the money, identity or integrity paths; licence surprises surface before, not after, a release build.

**Bad / costs:** hosted checkout is a slightly heavier UX than a native SDK sheet; the integrity platform channel is code we maintain ourselves.

**Follow-on work:** hosted-checkout return and deep-link handling in the contracts; integrity token verification Edge Function; dependency and licence scanning in CI so new additions are caught.

## Alternatives considered

| Option | Why not |
|---|---|
| Accept the packages and pin versions | Pinning does not fix an unmaintained dependency on the money path |
| Fork and maintain them ourselves | Cost with no product benefit |

## Revisit when

A rejected package gains a verified publisher and active maintenance, or S-04 forces the paid location SDK.
