# Lock State Transitions

The complete transition table. Ten transitions, four states.

## 1. States

| State | Holds shares? | Last action |
|---|---|---|
| `IDLE` | No | None |
| `LONG_LOCKED` | Yes | Buy within 5 trading days |
| `LONG_UNLOCKED` | Yes | Buy >5 trading days ago |
| `FLAT_LOCKED` | No | Sell within 5 trading days |
| `FLAT_UNLOCKED` | No | Sell >5 trading days ago |

## 2. Transition Table

| # | From | Action | Allowed | To | Notes |
|---|---|---|---|---|---|
| 1 | `IDLE` | Buy | ✅ | `LONG_LOCKED` | Entry |
| 2 | `IDLE` | Sell | ✅ | `FLAT_LOCKED` | Short not allowed; this is a no-op sell of 0 shares |
| 3 | `LONG_LOCKED` | Buy | ✅ | `LONG_LOCKED` | Adds; resets 5-day timer |
| 4 | `LONG_LOCKED` | Sell | ❌ | — | Blocked by lock |
| 5 | `LONG_UNLOCKED` | Buy | ✅ | `LONG_LOCKED` | Adds; starts new timer |
| 6 | `LONG_UNLOCKED` | Sell | ✅ | `FLAT_LOCKED` | Exit |
| 7 | `FLAT_LOCKED` | Sell | ✅ | `FLAT_LOCKED` | Adds to short; resets timer |
| 8 | `FLAT_LOCKED` | Buy | ❌ | — | Blocked by lock |
| 9 | `FLAT_UNLOCKED` | Buy | ✅ | `LONG_LOCKED` | Entry |
| 10 | `FLAT_UNLOCKED` | Sell | ✅ | `FLAT_LOCKED` | Short entry (not used) |

## 3. Timer Reset

Every same-direction action resets the 5-day timer.

- Row 3: A buy while `LONG_LOCKED` resets the timer. The lock expiry is
  now 5 trading days from the new buy, not the original.
- Row 7: A sell while `FLAT_LOCKED` resets the timer. The lock expiry is
  now 5 trading days from the new sell.

This is the "you may always add, never reverse" interpretation.

## 4. Timeout Transitions

These are not triggered by an order. They occur when the trading-day
clock advances past the `lock_expiry_date`.

| From | Trigger | To |
|---|---|---|
| `LONG_LOCKED` | `today > lock_expiry_date` | `LONG_UNLOCKED` |
| `FLAT_LOCKED` | `today > lock_expiry_date` | `FLAT_UNLOCKED` |

The lock monitor runs at market open on every trading day. For each
ticker, it checks whether the `lock_expiry_date` has passed and emits
a `LockTransition` event if so.

## 5. Forbidden Transitions

| From | Action | Reason |
|---|---|---|
| `LONG_LOCKED` | Sell | Constitution §1 |
| `FLAT_LOCKED` | Buy | Constitution §1 |
| `IDLE` | Short | Long-only system |
| Any | Short | Long-only system |

## 6. Edge Cases

**Partial fills:** A buy that fills 60% on day 1 and 40% on day 3 is
still one buy event. The lock timer starts on the first fill. The
`last_buy_date` is the date of the first fill.

**Cancelled orders:** A cancelled order does not change state. If a buy
was submitted but cancelled, the state remains unchanged.

**Rejected orders:** Same as cancelled. No state change.

**Ticker removed from universe:** If a veto activates while holding a
position, the position is exited on the next trading day (subject to
the lock). The lock does not prevent the exit; a veto exit is a forced
liquidation that overrides the lock. This is documented as an exception
in the constitution's veto section (07). The system logs the override
with `severity = CRITICAL`.

## 7. What Not to Do

- Do not add states beyond the five. More states means more bugs.
- Do not treat `IDLE` and `FLAT_UNLOCKED` as equivalent. They have
  different transitions.
- Do not reset the timer on a cancelled or rejected order.
- Do not skip the daily timeout check. Locks do not expire on their own.
- Do not allow the veto exit exception to fire silently. Log it.