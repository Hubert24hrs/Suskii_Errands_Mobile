# ADR-0020 — Suskii Meet: social meet-ups, designed around who can see what

| | |
|---|---|
| Status | Accepted |
| Date | 2026-10-24 |
| Deciders | Owner (chose "social meet-ups / events"); Claude Code |
| Related | migration `20261024120100_suskii_meet.sql`, `59_suskii_meet_test.sql`, contracts 2.3.0 |

## Context

The owner asked for "Suskii Meet, where people can meet up", directly under the concierge on the home screen, and chose social meet-ups and events over a meet-up point for errands. It is the platform's first feature in which strangers arrange to be in the same place with no job, no payment and no verified provider between them. The main risks are therefore safety and privacy, not throughput.

## Decision

- **Visibility.** Only signed-in people in the meet-up's own country see it; nobody signed out. People who have blocked each other (`blocks`, either direction) never see each other's meet-ups and cannot join them. A meet-up rejected by moderation disappears for everyone but the host.
- **What is stored.** A venue name and one point, chosen by the host as a public place. No home address, no live location. The caller's position is sent only to sort and filter the list, and is never written.
- **People.** The attendee list is shown only to the host and to the people going, by first name. Everyone else sees a count.
- **Moderation.** Title, description and venue go through `private.moderate_text`, the same deterministic rules as a request: `block` refuses, and `hold` publishes and opens a `moderation_cases` row (OD-21 fail-open). Upholding the case cancels the meet-up, through a trigger, so `decide_moderation_case` is not rewritten.
- **Limits.** A meet-up starts 30 minutes to 90 days ahead and lasts at most 24 hours. Capacity is 2–500. A host has at most `meetup_max_active_hosted` (3, remote config) upcoming meet-ups. A row lock serialises joins, so the last place cannot be taken twice.
- **Access.** The tables have no client grant at all. The eight functions are the only door, so the rules live in one place, the way `get_provider_card` works.
- **Notifications.** Cancelling notifies everyone going. The push carries the meet-up id only, never the title or venue, so a lock screen shows only that a meet-up was cancelled.
- **Lifecycle.** The data export lists meet-ups hosted and joined. Erasure deletes them and tells anyone going to an upcoming one.
- **No identity verification** is required to host or join, per the owner's decision that verification is for service providers ([ADR-0021](0021-verification-for-providers-only.md)).

## Consequences

- Safety copy is shown on the list, the detail and the form. It says to meet in busy public places, to tell someone you trust, and never to send money.
- Reporting a host uses the existing `reports` path against the host's user id. A dedicated in-feature report button is a follow-up.
- Not built, and worth deciding with the client: chat between attendees, recurring meet-ups, paid events (which would need the payment gateway), and age limits (a policy and legal question, OD-24 territory).
