---
name: rust-event-bus
description: Tokio-based event infrastructure for Rust modules. Load when
  touching execution/, the event bus, channels, or event handlers.
---

# Rust Event Bus

The event bus is the spine of the Rust execution engine. Every module
communicates through it: market data arrives, order events fire, locks
transition, and risk gates react. It is built on Tokio and uses bounded
channels throughout.

## 1. Architecture

The bus is not a generic pub/sub broker. It is a set of **typed channels**,
one per event class, with explicit backpressure and idempotency rules.

```
┌──────────────────────────────────────────────────────────────────┐
│                    EVENT BUS (Tokio)                              │
│                                                                   │
│  Channel: market_data  (bounded, capacity 1000)                  │
│  Channel: order_events (bounded, capacity 100)                   │
│  Channel: lock_events  (bounded, capacity 50)                    │
│  Channel: regime       (bounded, capacity 10)                    │
│  Channel: filing       (bounded, capacity 20)                    │
│  Channel: audit        (bounded, capacity 10000)                 │
└──────────────────────────────────────────────────────────────────┘
```

Each channel has one or more producers and one or more subscribers. The
subscriber count per channel is fixed at compile time. Dynamic
subscription is not supported.

## 2. Bounded Channels, Always

Every channel is bounded. Unbounded channels mask backpressure and lead
to OOM under load . The bus uses `tokio::sync::mpsc` for
single-consumer channels and `tokio::sync::broadcast` for multi-consumer
channels.

See `CHANNELS.md` for the capacity per channel and the overflow policy.

## 3. Event Types

See `EVENT-TYPES.md`. The bus dispatches nine event classes:

| Event | Priority | Channel |
|---|---|---|
| `MarketData` | P3 | `market_data` |
| `OrderSubmitted` | P0 | `order_events` |
| `OrderFilled` | P0 | `order_events` |
| `OrderCancelled` | P0 | `order_events` |
| `LockTransition` | P0 | `lock_events` |
| `LockExpiry` | P0 | `lock_events` |
| `RegimeFlip` | P1 | `regime` |
| `FilingEvent` | P1 | `filing` |
| `AuditEvent` | P0 | `audit` |

Priority determines latency budget, not channel. See `CHANNELS.md` §3.

## 4. Idempotency

Every event carries an `event_id` (UUID). Handlers are idempotent: if
the same `event_id` is processed twice, the second processing is a no-op.

The bus maintains a deduplication set of processed `event_id`s with a
TTL of 24 hours. The set is a `DashSet<Uuid>` (concurrent hash set). A
handler checks the set before processing and inserts after.

**Why:** Tokio channels do not guarantee exactly-once delivery under all
conditions. A retry on error, a duplicate WebSocket frame, or a
reconnect can deliver the same event twice. Idempotency at the handler
boundary is the fix .

## 5. The Audit Channel

`audit` is a special channel. It has one subscriber (the audit writer)
and high capacity (10000). Every other channel's handlers write a
corresponding `AuditEvent` to this channel when they process an event.

The audit writer is append-only. It writes to `audit_log.parquet` and
never updates or deletes. See `scripts/audit-writer.rs`.

If the audit channel is full, the bus applies **backpressure to all
other channels**. Trading halts. This is intentional: no order can be
processed without an audit record.

## 6. Handler Lifecycle

Every handler follows the same pattern:

```rust
async fn handle_event(
    event: Event,
    dedup: &DashSet<Uuid>,
    audit_tx: &mpsc::Sender<AuditEvent>,
) -> Result<(), HandlerError> {
    // 1. Idempotency check
    if !dedup.insert(event.event_id()) {
        return Ok(());  // already processed
    }

    // 2. Process
    let result = process(&event).await;

    // 3. Audit
    let audit = AuditEvent::from_result(&event, &result);
    audit_tx.send(audit).await?;

    // 4. Return
    result
}
```

Idempotency check is first. Audit write is last, before return. If
processing panics, the audit record is not written, and the event is
retried by the sender (if applicable).

## 7. Backpressure

Bounded channels provide backpressure. When a channel is full, `send()`
awaits until space is available. The sender is blocked, not the receiver.

The overflow policy per channel is in `CHANNELS.md` §4. The default is
**block the sender**. For `market_data`, the policy is **drop oldest**,
because stale quotes are worse than no quotes.

## 8. What Not to Do

- Do not use unbounded channels. Every channel is bounded .
- Do not use `tokio::sync::broadcast` for single-consumer channels. Use
  `mpsc` for lower overhead.
- Do not skip the idempotency check. Duplicate events are real.
- Do not process an event before checking `event_id`. The check is first.
- Do not write to the audit channel without holding a lock on the file.
  The audit writer serializes writes.
- Do not poll channels where events belong. The bus is push-based.
- Do not add a new channel without updating `CHANNELS.md` and
  `EVENT-TYPES.md` in the same commit.

## 9. Verification

- [ ] A test asserts every channel is bounded
- [ ] A test asserts idempotency (same event twice produces one result)
- [ ] A test asserts backpressure (full channel blocks sender)
- [ ] A test asserts the audit channel is written before processing returns
- [ ] A test asserts duplicate `event_id` is a no-op
- [ ] No `unwrap()` on `send()` calls outside of `main.rs`

## 10. Related Skills

- `09-lock-state-machine` — produces `LockTransition` and `LockExpiry`
- `10-execution-schwab` — produces `OrderSubmitted`, `OrderFilled`
- `06-regime-detection` — produces `RegimeFlip`
- `00-constitution` §8 — the audit log contract