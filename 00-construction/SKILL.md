---
name: project-constitution
description: Non-negotiable rules for the quant trading system. Always loaded.
  Every other skill inherits from this one. If code violates any rule here,
  it is wrong regardless of what any other document says.
---

# Project Constitution

This file defines invariants. They do not change without an explicit
amendment committed to Git. When any other skill, comment, or instruction
conflicts with this file, this file wins.

## 1. The 5-Day Transaction Lock

A position may not reverse direction within 5 trading days of the last
same-direction action. This is enforced at order submission, not at
evaluation. Evaluation runs continuously; execution is gated.

State machine — the only valid states and transitions:

    IDLE ──buy──▶ LONG_LOCKED ──5d──▶ LONG_UNLOCKED
      │                │                    │
      │                │ buy (reset)        │ buy (reset)
      │                ▼                    ▼
      │           LONG_LOCKED          LONG_LOCKED
      │
      └──sell──▶ FLAT_LOCKED ──5d──▶ FLAT_UNLOCKED
                       │                    │
                       │ sell (reset)       │ sell (reset)
                       ▼                    ▼
                  FLAT_LOCKED          FLAT_LOCKED

Rules:
- 5 trading days = 5 days the market is open. Skip weekends and NYSE holidays.
- Buying more while LONG_LOCKED is permitted; it resets the timer.
- Selling while LONG_LOCKED is FORBIDDEN. No exceptions.
- Buying while FLAT_LOCKED is FORBIDDEN. No exceptions.
- The lock is checked against the `position_locks` table AND the broker's
  actual position. If they disagree, halt trading and reconcile.

See skill `09-lock-state-machine` for the full transition table.

## 2. Point-in-Time Integrity

Every fundamental datum must carry its `filing_date`. The `period_end` is
metadata, never a decision variable.

- A 10-Q filed 2024-02-15 for the quarter ending 2023-12-31 becomes usable
  on 2024-02-15, not 2023-12-31.
- Macro series are forward-filled from their release date, not their
  observation date.
- Cross-sectional ranks are computed per date using only that date's data.
- Any join between price data and fundamental data is an as-of join on
  `filing_date <= date`, never an equality join on `period_end`.

## 3. No Lookahead

No feature, target, calibration window, or evaluation metric may use data
that was not available at the forecast origin.

- Train/validation/test splits are chronological. Never random.
- The TCP calibration window is strictly prior to the forecast date.
- Forward-return targets use only future prices for label construction,
  never for feature construction.
- Backtests use purged and embargoed folds. Overlapping horizons require
  HAC standard errors with lag >= H.
- Any use of `Ticker.info` from yfinance is a snapshot, not a time series.
  It must be stamped at fetch time and used only forward from that point.

## 4. Language Boundaries

Each language owns a specific layer. Do not cross the boundary without
updating the relevant skill.

| Layer                          | Language | Owns                                      |
|--------------------------------|----------|-------------------------------------------|
| Model training, calibration,   | Julia    | GSPQR, TCP, EVT, HMM, conviction, PMPT    |
| portfolio optimization         |          |                                           |
| Execution, risk, lock state,   | Rust     | Order lifecycle, Schwab client, event bus |
| data ingestion                 |          |                                           |
| Frontend, API, visualization   | Bun/TS   | Dashboard, WebSocket push, manual override|

- Rust never trains models. Julia never places orders.
- Data exchange between Julia and Rust uses Arrow IPC. Never JSON for arrays.
- LightGBM models are trained in Julia and exported as `.txt`. Rust loads
  them via `bosk`. Never re-train in Rust.

See skills `12-julia-rust-bridge` and `15-ai-dev-workflow`.

## 5. Parquet Schema Immutability

Once a Parquet schema is written and used, column names and types are frozen.

- Additive changes only. New columns are appended, never inserted.
- Renaming a column requires a migration file and a version bump.
- Changing a dtype (e.g., float32 to float64) requires a migration.
- Every schema change is a separate commit with a clear message.
- The full schema inventory lives in skill `13-parquet-lake`.

If you need a different shape, write a new file. Do not mutate the old one.

## 6. Execution Constraints

- **NAV-tiered order execution.** See §6a. The execution tier is determined
  by the trailing 5-day mean NAV.
- **No shorts.** Long-only. The universe is ETFs of growth equities.
- **Cash buffer.** At least 2% of portfolio value remains in cash at all times.
- **Position cap.** No single name exceeds 5% of portfolio value.
- **Sector cap.** No GICS sector exceeds 25% of portfolio value.
- **Reconciliation.** Every day at market close, local positions are compared
  against Schwab's reported positions. Mismatch halts trading.

## 6a. NAV-Tiered Order Execution

Three tiers, checked at every order submission:

| Tier | Trailing 5-day mean NAV | Order policy |
|---|---|---|
| **Bootstrap** | < $2,500 | Fractional market orders only. Limit orders are not submitted. |
| **Transition** | $2,500 – $10,000 | Limit orders are the default. Market orders permitted only for fractional share quantities that cannot be expressed as whole-share limits. |
| **Standard** | > $10,000 | Limit orders only. Market orders are not submitted. |

Rules:
- The tier is checked at order submission time, not cached. A NAV crossing
  a tier boundary takes effect on the next order.
- The tier boundary is inclusive at the lower bound. NAV of exactly $2,500
  is Transition. NAV of exactly $10,000 is Standard.
- Schwab rounds limit orders up to whole shares. Fractional quantities are
  only expressible as market orders.
- In the Transition tier, the order generator produces a whole-share limit
  for the integer portion and a fractional market for the remainder.
- In the Standard tier, quantities are rounded to whole shares and the
  residual is returned to cash.
- The 5-day lock applies in all tiers. A fractional market order is still
  a buy or sell that triggers or resets the lock.
- The order-type enum in Rust contains both `Limit` and `Market` variants.
  The `Market` variant is only constructible inside the Bootstrap tier or
  the Transition tier's fractional path.

See skill `10-execution-schwab` §2a for the implementation.

## 7. Veto vs. Conviction

Fundamentals act in two distinct ways. They are never mixed.

- **Veto is binary.** A stock with any active veto trigger is removed from
  the eligible universe before optimization. It is not sized down. It is
  not traded. Conviction is irrelevant.
- **Conviction is bounded.** The multiplier is `clip(1.0 + 0.12 * z, 0.50, 1.25)`.
  It scales post-optimization weights. It never eliminates a position.
- **Valuation is excluded from conviction.** `sp_ratio` is already a GSPQR
  feature. Using valuation again double-counts it.

Veto triggers (any one is sufficient):
- Altman Z-Score < 1.8
- Going-concern qualification in latest 10-K
- Negative book value AND negative operating cash flow
- Pending delisting notice
- Material restatement in trailing 12 months
- Auditor resignation in trailing 12 months
- Debt covenant breach disclosed

Once triggered, a veto persists until a subsequent filing explicitly clears it.

See skill `07-fundamental-overlay`.

## 8. Audit Log

`audit_log.parquet` is append-only. Never update, never delete.

Every order, lock transition, veto trigger, regime flip, and manual override
writes a row. The row contains `event_id`, `timestamp`, `event_type`,
`ticker`, `actor`, `details` (JSON), and `severity`.

If the audit log is unwritable, halt trading. Do not proceed without it.

`portfolio_ledger.parquet` is append-only for new trading days. The
idempotency overwrite on a re-run of the same day is a defensive measure,
not a normal update path. `tax_lots.parquet` permits in-place update on
full close and reduction of `open_quantity` on partial close, as
documented in skill `16-portfolio-ledger`.

## 9. Model Output Contracts

The prediction pipeline produces three outputs per ticker per horizon.
Their names and semantics are fixed.

- `q_hat_lower`, `q_hat_upper` — TCP-calibrated 5% and 95% bounds
- `q_extreme_lower`, `q_extreme_upper` — EVT 1% and 99% bounds
- `conviction` — bounded multiplier in [0.50, 1.25]

The median forecast used by the optimizer is the GSPQR 50th percentile.
Never substitute the midpoint of the TCP interval. They are not the same.

## 10. When in Doubt

1. Check this file first.
2. Check the specific skill for the layer you are working on.
3. If neither answers, stop and ask. Do not invent a rule.
4. If a rule here is wrong, propose an amendment as a Git commit. Do not
   silently violate it.

## Verification Checklist

Before committing any change, confirm:

- [ ] No new code uses `period_end` as a decision variable
- [ ] No new code creates a random train/test split on time series
- [ ] No new code submits a market order outside the Bootstrap tier or
      the Transition tier's fractional path
- [ ] No new code violates the lock state machine
- [ ] No new code changes a Parquet schema without a migration
- [ ] No new code mixes veto and conviction logic
- [ ] No new code uses valuation as a conviction component
- [ ] Any new language-boundary crossing is documented in the relevant skill
- [ ] The audit log is written for every order and state change
- [ ] The execution tier is read from `portfolio_ledger.parquet` at
      submission time, not cached
- [ ] The change is committed with a message that references this file if it
      touches any invariant

## Amendment Process

To change this file:

1. Open a branch named `constitution/amendment-<short-description>`.
2. Edit only this file.
3. Commit with a message explaining what invariant changed and why.
4. Review against skills that reference the changed invariant.
5. Merge only after the affected skills are updated in the same PR.

Constitutional changes are rare. If you are proposing one weekly, the
constitution is too large. Move detail into layer-specific skills instead.