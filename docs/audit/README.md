# Audits

Claude Code audits all frontend and backend code after each Kimi Code integration milestone and before release (spec: `agent_claude_code.audit_responsibilities`).

Each audit is a dated file, `AUDIT-YYYY-MM-DD.md`, listing findings with severity, location, fix and status. Critical and high findings are fixed directly (backend) or filed for Kimi Code in `HANDOFF.md` (frontend). No audit is "closed" while a critical or high finding is open.

## Severity

| Severity | Meaning | Handling |
|---|---|---|
| Critical | Money can move wrongly, personal or biometric data can leak, auth can be bypassed, or safety features fail | Fix before the milestone is accepted; no exceptions |
| High | Security or correctness defect with a workaround, or a spec rule broken | Fix in the same phase |
| Medium | Performance, resilience or maintainability problem | Scheduled, tracked |
| Low | Style, docs, minor cleanup | Batched |

## Audit log

| Date | Scope | Critical | High | Status |
|---|---|---|---|---|
| [2026-09-17](AUDIT-2026-09-17.md) | Whole repository, at the user's request (Kimi Code mid-M3) | 0 | 2 — both **fixed**: M3.15 sign-in dead end (`e5c2f6f`), M3.18 frontend CI failing since M2 (`46cd262`) | Closed; Medium and Low items filed in `HANDOFF.md` |

## Checklists

The frontend checklist and the backend self-audit checklist are defined in the spec (`audit_responsibilities.frontend_audit_checklist` and `.backend_self_audit`). Phase 0 adds these project-specific checks:

- No package from the ADR-0010 rejection list is present in any lockfile.
- No UI string calls held funds "escrow" (any language file).
- Money values are integer minor units with a currency code everywhere; UGX (exponent 0) formats correctly.
- Trusted contacts use the Android Contact Picker, not `READ_CONTACTS`.
- Play declarations exist for foreground service types, full-screen intent and precise location.
- Every PushKit VoIP push reports to CallKit before the handler returns.
- No client-side computation of price, commission, gateway fee, payout or referral amounts; all come from a server quote object.
- Deep links and referral attribution cannot be spoofed into a reward.
