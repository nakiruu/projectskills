# Invariant Enforcement

Not every rule can be mechanically enforced. This file states, for each
invariant, whether it is caught by tooling, by tests, or only by review.
If an invariant is "review only," a human must check it before merge.

## Enforcement Classes

- **MECHANICAL** — a compiler, linter, CI check, or DB constraint rejects the
  violation. It cannot be merged.
- **TESTED** — a unit or integration test fails. Merge is blocked by CI.
- **REVIEW** — no automated check exists. Requires human sign-off.

---

## §1 Five-Day Lock — MECHANICAL + TESTED

Three layers:

1. **Rust typestate.** Lock states are types, not enums. `sell()` is not
   implemented on `LongLocked`, so a violating call does not compile.

   ```rust
   pub struct LongLocked { pub expiry: NaiveDate }
   pub struct LongUnlocked;
   pub struct FlatLocked { pub expiry: NaiveDate }
   pub struct FlatUnlocked;

   pub trait CanSell {}
   impl CanSell for LongUnlocked {}
   impl CanSell for FlatLocked {}
   // LongLocked intentionally omitted.

   impl LongLocked {
       pub fn sell(self) -> Result<Fill, LockViolation> {
           Err(LockViolation::LockedUntil(self.expiry))
       }
   }

DB constraint. position_locks has a CHECK that rejects any row where
last_buy_date and last_sell_date are within 5 trading days.

Daily reconciliation. A Rust job compares local positions to Schwab at
close. Mismatch sets a global halt flag in the audit log.

Test coverage: tests/lock_state_machine.rs exercises all 10 transitions.

§2 Point-in-Time Integrity — MECHANICAL + REVIEW
Mechanical portion:

A Julia helper as_of_join(panel, fundamentals) is the only sanctioned way
to join price and fundamental data. It uses filing_date <= date.

A linter rule bans the identifier period_end outside of ingestion code.
Any use in features/, models/, or backtest/ is a CI failure.

Review portion:

Whether a new data source provides point-in-time or restated data cannot
be checked mechanically. A human must confirm the vendor's semantics before
the source is added.

§3 No Lookahead — MECHANICAL + TESTED
The train/test split function asserts chronological ordering at runtime and
raises if it detects overlap.

Backtests use a purged, embargoed K-fold implementation. Writing your own
split without using this helper fails a CI check that greps for
train_test_split and KFold outside the approved module.

Target construction is isolated in features/targets.jl. No other file may
reference shift(-N) or forward indexing.

Review portion:

Whether a feature encodes information that would not have been available
at decision time. Example: a "revenue surprise" feature computed from
revised data. No linter catches this.

§4 Language Boundaries — MECHANICAL
A CI job inspects file extensions per directory:

Path prefix	Allowed extensions
models/, portfolio/, regime/, conviction/	.jl
execution/, ingest/, risk/	.rs
frontend/, api/	.ts, .tsx
A .rs file in models/ is a CI failure. No exceptions.

§5 Parquet Schema Immutability — MECHANICAL
A schemas/registry.json file stores a SHA-256 hash of each Parquet schema,
keyed by filename. A CI job reads every Parquet file's schema, hashes it, and
compares to the registry. Mismatch without a corresponding migration file in
migrations/ is a CI failure.

Adding a column: append to the schema, update the registry hash, add a
migration file. The migration must be additive-only, verified by a test that
asserts no column was removed or retyped.

§6 Execution Constraints — MECHANICAL
Before any order is submitted, a Rust guard checks:

order_type is in {Limit, Stop, StopLimit, OCO, Bracket, MOC, LOC}.
Market is not in the enum. It cannot be constructed.

Resulting position weight ≤ 0.05.

Resulting sector weight ≤ 0.25.

Resulting cash ≥ 0.02 of portfolio value.

Side is Buy or Sell. Short is not representable.

All five are compile-time or pre-submit runtime checks. No order reaches Schwab
without passing them.

§7 Veto vs. Conviction — TESTED + REVIEW
Tested:

tests/veto_conviction_separation.rs asserts that a vetoed ticker receives
weight exactly 0.0 in the final portfolio, regardless of conviction value.

tests/conviction_bounds.rs asserts the multiplier stays in [0.50, 1.25]
across 10,000 random composite z-scores.

Review portion:

Whether a new conviction component duplicates an existing GSPQR feature.
This requires judgment. The reviewer checks the component against the
12-feature list in skill 03-gspqr-model.

§8 Audit Log — MECHANICAL
audit_log.parquet is written with a file lock held for the duration of
any order or state transition.

The Rust audit writer is the only component with write access. It exposes
append(event) and no update or delete.

If the append fails, the calling code returns an error and does not proceed.
There is no fallback path.

§9 Model Output Contracts — MECHANICAL
Prediction outputs are a Rust struct with named fields. Renaming a field
breaks compilation downstream. No string-keyed maps.

The Julia side writes an Arrow table whose schema is checked against the
Rust struct's field names at startup. Mismatch is a hard failure.

§10 Amendment Process — REVIEW
Process-only. Enforced by convention:

Branch name must match constitution/amendment-*. A CI job checks this on
any PR touching SKILL.md.

CODEOWNERS requires two approvals for changes to 00-constitution/.

Summary Table
§	Invariant	Class
1	Five-day lock	MECHANICAL + TESTED
2	Point-in-time	MECHANICAL + REVIEW
3	No lookahead	MECHANICAL + TESTED
4	Language boundaries	MECHANICAL
5	Schema immutability	MECHANICAL
6	Execution constraints	MECHANICAL
7	Veto vs. conviction	TESTED + REVIEW
8	Audit log	MECHANICAL
9	Output contracts	MECHANICAL
10	Amendment process	REVIEW
Three invariants have a review component. Those are the ones to be careful
about in code review, because no tool will catch a mistake.
