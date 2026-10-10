---
name: lock-state-machine
description: The 5-day transaction lock. Load when touching execution/locks/,
  position state, pending orders, or any order gating code.
---

# The 5-Day Lock

The lock prevents any reversal of direction within 5 trading days of the
last same-direction action. This is the constitution's first invariant
(§1). Every order submission must pass through it.

## 1. The Rule in One Sentence

You may always add to a position in the same direction; you may never
reverse direction within 5 trading days.

## 2. The Four States

| State | Meaning | Buy? | Sell? |
|---|---|---|---|
| `IDLE` | No position, no recent action | ✅ | ✅ |
| `LONG_LOCKED` | Holding, buy within 5 days | ✅ (resets) | ❌ |
| `LONG_UNLOCKED` | Holding, buy >5 days ago | ✅ | ✅ |
| `FLAT_LOCKED` | Flat, sell within 5 days | ❌ | ✅ (resets) |
| `FLAT_UNLOCKED` | Flat, sell >5 days ago | ✅ | ✅ |

That is five states, not four. `IDLE` and `FLAT_UNLOCKED` are distinct:
`IDLE` means no position and no recent sell; `FLAT_UNLOCKED` means no
position and the last sell was >5 days ago. Both permit buys, but the
distinction matters for the transition table.

## 3. Trading-Day Counting

The 5-day window counts **trading days only**. Weekends and NYSE
holidays are skipped.

**Implementation:** The lock's `lock_expiry_date` is computed by
advancing 5 trading days from the last same-direction fill date. The
trading calendar is sourced from `prices.parquet` (distinct dates where
the universe had trading activity).

**Do not** use calendar days. A sell on Friday means the lock expires on
the following Friday, not the following Wednesday.

## 4. Enforcement Points

The lock is enforced at **three layers**:

**Layer 1: Compile-time (Rust typestate).**
Lock states are types, not enums. `sell()` is not implemented on
`LongLocked`. A violating call does not compile. See §6.

**Layer 2: Runtime pre-submit check.**
Before submitting any order, the execution engine queries
`position_locks.parquet` and the broker's actual position. If the order
would reverse direction within the lock window, it is rejected.

**Layer 3: Daily reconciliation.**
After market close, local positions are compared against Schwab's
reported positions. Mismatch halts trading.

## 5. The State Transition Table

See `STATE-TRANSITIONS.md` for the complete table. The summary:

| From | Action | Allowed | To |
|---|---|---|---|
| `IDLE` | Buy | ✅ | `LONG_LOCKED` |
| `IDLE` | Sell | ✅ | `FLAT_LOCKED` |
| `LONG_LOCKED` | Buy | ✅ | `LONG_LOCKED` (reset timer) |
| `LONG_LOCKED` | Sell | ❌ | — |
| `LONG_UNLOCKED` | Buy | ✅ | `LONG_LOCKED` |
| `LONG_UNLOCKED` | Sell | ✅ | `FLAT_LOCKED` |
| `FLAT_LOCKED` | Sell | ✅ | `FLAT_LOCKED` (reset timer) |
| `FLAT_LOCKED` | Buy | ❌ | — |
| `FLAT_UNLOCKED` | Buy | ✅ | `LONG_LOCKED` |
| `FLAT_UNLOCKED` | Sell | ✅ | `FLAT_LOCKED` |

## 6. Compile-Time Enforcement (Rust)

```rust
pub struct LongLocked {
    pub expiry: NaiveDate,
}
pub struct LongUnlocked;
pub struct FlatLocked {
    pub expiry: NaiveDate,
}
pub struct FlatUnlocked;

pub trait CanSell {}
impl CanSell for LongUnlocked {}
impl CanSell for FlatLocked {}

pub trait CanBuy {}
impl CanBuy for LongLocked {}
impl CanBuy for FlatUnlocked {}
impl CanBuy for LongUnlocked {}

impl LongLocked {
    // Note: no `sell` method exists
    pub fn buy(self, more: i64) -> Result<LongLocked, LockError> {
        Ok(LongLocked { expiry: add_trading_days(self.expiry, 5) })
    }
}

impl LongUnlocked {
    pub fn sell(self, qty: i64) -> Result<FlatLocked, LockError> {
        Ok(FlatLocked { expiry: today_plus_trading_days(5) })
    }
    pub fn buy(self, qty: i64) -> Result<LongLocked, LockError> {
        Ok(LongLocked { expiry: today_plus_trading_days(5) })
    }
}
```

Attempting to call `.sell()` on a `LongLocked` produces a compile
error. This is the strongest guarantee the system can offer.

## 7. Pending Orders

See `PENDING-ORDERS.md`. When the target portfolio wants a position that
the lock blocks, the order is written to `pending_orders.parquet` with an
`earliest_execution` date. At market open on that date, a Rust timer
fires, re-validates the signal, and either submits or cancels.

**The re-validation step is critical.** A signal that was correct when
queued may have reversed by expiry. Firing blindly executes a stale
decision.

## 8. What Not to Do

- Do not count calendar days. Count trading days.
- Do not allow a sell while `LONG_LOCKED`. No exceptions.
- Do not allow a buy while `FLAT_LOCKED`. No exceptions.
- Do not skip the compile-time enforcement. Use typestate.
- Do not fire pending orders without re-validating the signal.
- Do not trust the local lock table without daily reconciliation.
- Do not mix the lock gate with the regime gate. They are separate
  controls at separate layers.

## 9. Verification

- [ ] A test asserts all 10 transitions in the table
- [ ] A test asserts the 5-day window counts trading days
- [ ] A test asserts a violating Rust call does not compile
- [ ] A test asserts pending orders re-validate on expiry
- [ ] A test asserts reconciliation halts trading on mismatch
- [ ] A test asserts no order is submitted without a lock check

## 10. Related Skills

- `00-constitution` §1 — the lock invariant
- `10-execution-schwab` — where the lock is enforced before submission
- `11-rust-event-bus` — produces `LockTransition` and `LockExpiry` events
- `13-parquet-lake` — schemas for `position_locks` and `pending_orders`