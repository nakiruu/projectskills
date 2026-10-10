# Anti-Patterns

Common mistakes on this codebase, with the fix. If you catch yourself
writing one of these, stop.

## Data

### AP-1: Using `period_end` as a decision variable
**Why it is wrong:** It is lookahead. The data was not public until
`filing_date`.
**Fix:** Always join on `filing_date <= date`. Linter catches this in
`features/`, `models/`, `portfolio/`, `conviction/`. If you are outside those
directories and about to use `period_end`, stop.

### AP-2: Random train/test splits
**Why it is wrong:** Time series data is not exchangeable. Random splits
leak future information into the training set.
**Fix:** Use `backtest/splits.jl` which implements purged, embargoed
walk-forward. Never call `train_test_split` or `KFold` directly.

### AP-3: Forward-filling fundamentals across a filing
**Why it is wrong:** Fills the gap between `period_end` and `filing_date`
with data that was not yet public.
**Fix:** Forward-fill from `filing_date` forward, not from `period_end`.

### AP-4: Computing cross-sectional ranks with fewer than 50 names
**Why it is wrong:** Ranks become coarse and unstable. With Mag7 alone,
the rank is 1–7, which is not a meaningful cross-sectional signal.
**Fix:** Compute ranks only on the full eligible universe (IWF + IWP,
~600 names). Flag any subset computation for review.

## Modeling

### AP-5: Non-chronological calibration windows
**Why it is wrong:** TCP requires the calibration set to be strictly prior
to the forecast origin. Including same-day data breaks coverage guarantees.
**Fix:** Use `date < forecast_date` for calibration. Not `<=`.

### AP-6: Fitting GPD to raw returns
**Why it is wrong:** The EVT layer operates on calibrated residuals, not
raw returns. The residuals are what remains after the model has explained
the central tendency.
**Fix:** Compute residuals from the TCP calibration step. Fit GPD to those.

### AP-7: Using mean/std for cross-sectional standardization
**Why it is wrong:** Fundamentals have fat tails and outliers. Mean/std is
not robust.
**Fix:** Median/MAD, winsorized at ±3.

### AP-8: Adding valuation to conviction
**Why it is wrong:** `sp_ratio` is already a GSPQR feature. Adding valuation
again double-counts it and distorts the interval.
**Fix:** Conviction uses only quality signals (F-Score, ROIC spread, accruals,
margin trend, revenue persistence, revisions). No valuation.

## Execution

### AP-9: Submitting market orders
**Why it is wrong:** Violates constitution §6. Market orders accept any
fill price, which is unacceptable for a system with a 5-day lock.
**Fix:** Limit orders only. The order type enum does not include `Market`.

### AP-10: Checking lock state against the local table only
**Why it is wrong:** The local table can drift from broker state. Relying on
it without reconciliation risks violating the lock.
**Fix:** Every order submission checks both the local `position_locks` table
AND the daily reconciliation result. If they disagree, halt.

### AP-11: Firing pending orders without signal re-validation
**Why it is wrong:** A signal that was correct at queue time may have
reversed by lock expiry. Firing blindly executes a stale decision.
**Fix:** Re-fetch the latest signal at expiry. Cancel if direction reversed.

## Infrastructure

### AP-12: Polling where events belong
**Why it is wrong:** Wastes CPU, introduces latency, and violates the
event-driven architecture.
**Fix:** Subscribe to the event bus. Polling is only for reconciliation
jobs, which run on a fixed schedule by design.

### AP-13: Unbounded channels
**Why it is wrong:** Masks backpressure. Under load, memory grows until
OOM.
**Fix:** Bounded channels with explicit overflow policy (drop, block, or
fail). The policy is documented at the call site.

### AP-14: `unwrap()` in library code
**Why it is wrong:** Panics on unexpected input. In an execution system,
a panic is a trading halt at best and a partial fill at worst.
**Fix:** `?` with typed errors via `thiserror`. `unwrap()` is only allowed
in `main.rs` and tests.

### AP-15: JSON for array exchange across FFI
**Why it is wrong:** Slow, lossy, and loses dtype information.
**Fix:** Arrow IPC. Both Julia (`Arrow.jl`) and Rust (`arrow`) support it
natively. Zero-copy where possible.

## Working with Claude

### AP-16: Editing files without reading them
**Why it is wrong:** The file may have changed since your last context.
Editing based on memory produces incoherent diffs.
**Fix:** Read before edit. Always.

### AP-17: Claiming a task is done without running tests
**Why it is wrong:** The verification protocol exists because LLM-generated
code is often plausible-looking but wrong.
**Fix:** Run the tests. If you cannot run them, say so and mark the task as
unverified, not done.

### AP-18: Weakening a check to make a test pass
**Why it is wrong:** The check encodes an invariant. Weakening it to pass
your code inverts the purpose of the test suite.
**Fix:** Fix the code. If the check is genuinely wrong, propose a skill
amendment. Do not edit the check inline.

### AP-19: Improvising when a task does not fit the skills
**Why it is wrong:** The skills cover the system. A task that does not fit
is either miscategorized or requires a new skill. Improvising produces code
with no rules and no review.
**Fix:** Stop and ask. The user decides whether the skill is missing or the
task is out of scope.

### AP-20: Reading skills after writing code
**Why it is wrong:** The skill defines the constraints. Writing first and
checking later means rewriting or, worse, shipping a violation.
**Fix:** Read the layer skill before writing. If you forgot, read it now
and audit the code you already wrote.