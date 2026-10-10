# Pending Orders

When the target portfolio wants a position that the lock blocks, the
order is queued. At lock expiry, the queue is re-validated and fired.

## 1. The Queue

`pending_orders.parquet` holds every order that is waiting on a lock.

| Column | Type | Notes |
|---|---|---|
| `pending_id` | `utf8` | UUID |
| `ticker` | `utf8` | |
| `side` | `utf8` | `Buy` / `Sell` |
| `target_quantity` | `int64` | |
| `earliest_execution` | `date32` | Lock expiry |
| `signal_snapshot` | `utf8` | JSON of quantiles at queue time |
| `created_at` | `timestamp[ns, UTC]` | |
| `status` | `utf8` | `Pending` / `Fired` / `Cancelled` / `Expired` |
| `cancelled_reason` | `utf8` | `signal_reversed` / `lock_extended` / null |

## 2. The Queueing Rule

When a target order is generated but the lock blocks it:

1. Compute the earliest execution date (lock expiry).
2. Capture the current signal as a JSON snapshot.
3. Write a row to `pending_orders.parquet` with `status = Pending`.
4. Do not submit the order.

The order is not submitted on the current date. It waits.

## 3. The Expiry Rule

At market open on `earliest_execution`:

1. Load all pending orders with `earliest_execution == today` and
   `status == Pending`.
2. For each, fetch the latest signal from `gspqr_predictions.parquet`
   and `tcp_calibration.parquet`.
3. Compare the latest signal to the `signal_snapshot`.
4. If the direction is unchanged (or strengthened):
   - Submit the order.
   - Update `status = Fired`.
5. If the direction reversed:
   - Cancel the order.
   - Update `status = Cancelled`, `cancelled_reason = signal_reversed`.
6. If the lock extended (a new same-direction action occurred):
   - Update `earliest_execution` to the new lock expiry.
   - Keep `status = Pending`.

**The re-validation is the load-bearing step.** Firing a stale signal
executes a decision the system no longer believes in.

## 4. Signal Comparison

The `signal_snapshot` captures the GSPQR quantiles at queue time:

```json
{
  "q_05": -0.042,
  "q_50": 0.081,
  "q_95": 0.198,
  "conviction": 1.089,
  "regime_factor": 1.0
}
```

At expiry, the latest signal is fetched. The comparison rule:

| Current vs. Snapshot | Action |
|---|---|
| `q_50` sign unchanged, magnitude ≥ 50% of snapshot | Fire |
| `q_50` sign unchanged, magnitude < 50% of snapshot | Cancel (`signal_weakened`) |
| `q_50` sign reversed | Cancel (`signal_reversed`) |
| Veto activated | Cancel (`veto_triggered`) |
| Regime flipped to crisis | Cancel (`regime_crisis`) |

## 5. Order Lifecycle

```
                        ┌── Pending ──┬── Fired
                        │             │
Target generated ───────┤             ├── Cancelled
                        │             │
                        │             └── Expired
                        │
                        └── (if lock extends, update earliest_execution)
```

- **Pending:** queued, waiting for lock expiry.
- **Fired:** submitted on expiry after re-validation.
- **Cancelled:** signal reversed, weakened, vetoed, or regime-shifted.
- **Expired:** `earliest_execution` passed by more than 5 trading days
  without firing. This is a bug indicator. Log and alert.

## 6. What Not to Do

- Do not fire a pending order without re-validating the signal.
- Do not queue an order that is not blocked by the lock.
- Do not extend `earliest_execution` beyond the new lock expiry.
- Do not cancel a pending order because the signal is unchanged. That is
  the correct state to fire.
- Do not skip the `Expired` status. It catches stuck orders.
- Do not store the signal snapshot as anything other than JSON. It is
  unstructured by design.

## 7. Verification

- [ ] A test queues an order and fires it on expiry with an unchanged signal
- [ ] A test queues an order and cancels it when the signal reverses
- [ ] A test extends `earliest_execution` when the lock extends
- [ ] A test asserts expired orders are flagged
- [ ] A test asserts the signal snapshot round-trips through JSON