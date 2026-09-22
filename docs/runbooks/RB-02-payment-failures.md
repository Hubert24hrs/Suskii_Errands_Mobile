# RB-02 — Payments are failing, or jobs are stuck waiting for one

| | |
|---|---|
| Owner | Claude Code / ops |
| Severity | SEV1 if no payment is confirming in a live country; SEV2 if one gateway or method is failing; SEV3 for a single stuck job |
| Last rehearsed | **Not yet.** Rehearse on staging before the first live country (RB-08 gate) |
| Related | ADR-0002 (held, never escrow); money-flows 1a–1d; RB-01, RB-03, RB-04, RB-14; `docs/audit/AUDIT-2026-09-22.md` T.1 |

## What the money is doing at each status

`public.payments.status` is `unpaid → pending → held`, with `failed`, `refunded` and
`partially_refunded` as the ends. The request moves in step (job state machine 7, 8, 9, 10).

| Payment | Request | Money position | Who moves it |
|---|---|---|---|
| `unpaid` | `agreed` | nothing taken | customer calls `start_payment` |
| `pending` | `payment_pending` | customer may have been charged, unconfirmed | gateway webhook |
| `held` | `paid_held` → `assigned` | `held_funds` (posting 1a) | `private.confirm_payment`, webhook only |
| `failed` | stays `payment_pending` until the TTL | nothing held | gateway webhook |

**A client cannot confirm its own payment.** `private.confirm_payment` has no grant to any client
role and `29_payments_test` asserts it. The only doors are `public.gateway_confirm_payment` and
`public.gateway_ingest_webhook`, granted to `service_role` alone because PostgREST cannot reach
`private`.

## Symptoms

- Customers report paying and the job not starting.
- `payment_pending` count climbing; the `payment-ttl` cron (`*/5 * * * *`) expiring more than it
  usually does.
- `get_health()` shows `outbox_stuck` degraded, or `webhook_partition` unhealthy.
- Gateway status page, or a spike in `payments.status = 'failed'` for one method or one country.

## Impact

Customers are charged or think they are, and no provider is assigned. This is money and it is
visible, so it is at least SEV2 the moment more than one customer is affected.

## Immediate actions (first 5 minutes)

1. Open the incident (RB-01) and say in the channel which country and which gateway.
2. Establish **whether money is being taken**. A gateway that declines cleanly is an inconvenience;
   a gateway that charges and does not call back is a refund problem in the making.
   ```sql
   SELECT status, count(*), min(created_at), max(created_at)
   FROM public.payments WHERE created_at > now() - interval '2 hours' GROUP BY 1 ORDER BY 2 DESC;
   ```
3. Check the webhook is arriving at all:
   ```sql
   SELECT count(*), max(received_at) FROM public.webhook_events
   WHERE received_at > now() - interval '1 hour';
   ```
   A `max(received_at)` older than a few minutes during trading hours means the webhook is not
   reaching us, and nothing downstream will fix itself.
4. If one payment **method** is failing and others are fine, switch that method off for the country
   (RB-13) rather than declaring a full outage.

**Stop conditions.**

- **Never mark a payment `held` by hand.** It posts to the ledger. If the money genuinely arrived,
  replay the gateway's webhook — that path verifies server-side and is idempotent on the event id.
- **Never edit `ledger.entries`.** The ledger is append-only and `ledger.reconcile()` will find you.
- **Never refund from the gateway console** while the platform thinks funds are held. Use
  `execute_refund` so the books and the gateway agree; a console refund is RB-03 tomorrow.

## Diagnosis

| Check | Where | Healthy looks like |
|---|---|---|
| Webhooks arriving | `public.webhook_events`, `max(received_at)` | Within minutes during trading hours |
| Duplicate suppression working | `webhook_events` grouped by gateway event id | One row acted on per event; duplicates stored, not re-posted |
| Partitions exist for today | `SELECT * FROM private.partition_health();` | Every partitioned table has a partition covering now and the next month |
| Outbox draining | `SELECT private.outbox_stuck_count();` | Small and falling |
| Worker running | `payments-worker` logs; `outbox-stuck-check` cron every 10 min | Claims and completes; no claim held longer than its lease |
| Gateway itself | Vendor status page and the worker's own error text | — |

**The failure that hides:** audit finding T.1. `webhook_events` is partitioned, and if partition
creation stops, inserts fail and **every payment stops confirming while every other health check
stays green**. `private.partition_health()` exists to make that visible and the `partition-health`
cron runs at 03:19 daily. If you are here and payments stopped for no visible reason, run it first.

## Resolution

**A. The webhook never arrived (gateway-side).**

1. Confirm with the gateway dashboard that the event exists and what it says.
2. Replay it from the gateway's own console. The endpoint verifies the signature over the raw
   body, stores it, de-duplicates across partitions and then verifies server-side, so a replay is
   safe and a duplicate is a no-op.
3. Confirm the request moved:
   ```sql
   SELECT r.status, p.status FROM public.requests r
   JOIN public.payments p ON p.request_id = r.id WHERE r.id = :request_id;
   ```

**B. The webhook arrived and was stored but nothing happened.**

Look for the event and whether it was acted on. If it was stored but not processed, the worker is
the problem, not the gateway — check `payments-worker` logs and whether `private.claim_outbox` is
handing out work. `FOR UPDATE SKIP LOCKED` means a crashed worker leaves a claim behind; the lease
expires and another worker picks it up, so wait one cycle before intervening.

**C. Payments are expiring because customers cannot complete checkout.**

The `payment-ttl` cron returns the request to `agreed` (job machine transition 9), not to
`negotiating` — the accepted offer still stands and the customer may start payment again at the
same price. That is the designed recovery and usually the right one. If checkout itself is broken,
switch the method off (RB-13) so customers stop being sent to a dead page.

**D. Partitions are missing.**

```sql
SELECT private.record_partition_health();
SELECT * FROM private.partition_health();
```
If a partition is genuinely absent, create the next months and then re-drive the stuck webhooks
from the gateway console.

## Backout

Nothing here changes schema or code, so there is little to back out. If a feature flag was flipped
to disable a method, flip it back (RB-13) once the gateway confirms recovery, and watch the first
ten payments individually before declaring it over.

## Communication

- **Customers with money taken and no provider:** tell them the same day, say the money is held and
  not lost, and give the refund timeline. Do not wait for the incident to close.
- **Providers who were assigned and then unassigned:** they gave up other work. Say so plainly.
- **Finance:** any manual gateway action at all, immediately, or RB-03 fires tomorrow morning and
  nobody knows why.
- **Regulator:** only if personal data was exposed (RB-07). A payment outage on its own is not a
  breach.

## After the incident

- Timeline within 24 h, including how long money sat charged-but-unconfirmed.
- If any payment was resolved by hand, file the reconciliation follow-up **before** closing.
- If `partition_health` was the cause, ask why the alert did not fire first and tune it.
- Add the gateway's failure mode to the table above; the second time is meant to be faster.
