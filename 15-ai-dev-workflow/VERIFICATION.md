# Verification Protocol

Every task ends with this checklist. It is not a suggestion.

## Universal Checks (every change)

- [ ] I read the relevant layer skill this session
- [ ] I read the constitution this session
- [ ] I can name the layer this change belongs to
- [ ] The change does not violate any of the ten invariants
- [ ] If the change touches a Parquet schema, the schema registry is updated
- [ ] If the change touches an invariant, `AMENDMENTS.md` is updated
- [ ] A test exists and passes for the new behavior
- [ ] I ran `pre-commit-constitution.sh` and it passed
- [ ] The commit message follows `COMMIT-CONVENTIONS`

## Layer-Specific Checks

### Ingestion (01)
- [ ] All fundamental data is stamped with `filing_date`, not `period_end`
- [ ] Rate limits are respected per source
- [ ] Failures write to `data_quality.parquet`
- [ ] Retry logic is bounded (no infinite loops)

### Panel (02)
- [ ] Cross-sectional ranks use only that date's data
- [ ] Rolling windows do not extend past the current date
- [ ] Forward returns are NaN where the horizon exceeds available data
- [ ] Z-score uses the 60-day trailing window, not expanding

### GSPQR (03)
- [ ] Training split is chronological
- [ ] Hyperparameters match the current skill spec
- [ ] Model is exported to `.txt`, not serialized in a language-specific format
- [ ] Feature matrix has exactly 12 columns in the documented order

### TCP (04)
- [ ] Conformity scores are zero-truncated
- [ ] Window parameters (`w`, `m`, `α`) match the skill spec
- [ ] Robbins-Monro offset is updated with decaying step size
- [ ] Calibration window is strictly prior to the forecast date

### EVT (05)
- [ ] GPD is fit to calibrated residuals, not raw returns
- [ ] Threshold is at the 95th percentile of residuals
- [ ] At least 50 exceedances are used per fit
- [ ] Separate fits for lower and upper tails

### Regime (06)
- [ ] HMM has exactly 3 states
- [ ] Confirmation rule (2 consecutive days) is applied before acting
- [ ] Regime factor maps to {1.0, 0.5, 0.0}

### Conviction (07)
- [ ] Veto is binary, conviction is bounded
- [ ] No valuation component (would double-count GSPQR's `sp_ratio`)
- [ ] Median/MAD standardization, not mean/std
- [ ] Multiplier clipped to [0.50, 1.25]

### Portfolio (08)
- [ ] Conviction applied after optimization, not before
- [ ] Weights renormalized with iterative cap redistribution
- [ ] Constraints: 5% single-name, 25% sector, 2% cash

### Lock (09)
- [ ] State machine matches the constitution
- [ ] 5 trading days, not calendar days
- [ ] Pending orders re-validate signal on lock expiry

### Execution (10)
- [ ] No market orders
- [ ] Limit-only submission
- [ ] Reconciliation runs daily
- [ ] Audit log written for every state change

### Event Bus (11)
- [ ] No polling where events belong
- [ ] Channels are bounded with explicit backpressure policy
- [ ] Handlers are idempotent

### FFI (12)
- [ ] Arrow IPC for array exchange, not JSON
- [ ] Memory ownership documented
- [ ] LightGBM handoff uses `.txt` format

### Parquet (13)
- [ ] Schema change is additive only
- [ ] Schema registry hash updated
- [ ] Migration file added if needed

### Backtest (14)
- [ ] Walk-forward with purged, embargoed folds
- [ ] HAC standard errors for overlapping horizons
- [ ] Coverage reported per regime, not just overall

## When a Check Fails

1. Do not weaken the check. Fix the code.
2. If the check is genuinely wrong, propose an amendment to the skill that
   defines it. Do not edit the check inline.
3. If you cannot fix the code, stop and report. Do not proceed with a
   known-failing check.

## What "Passes Locally" Means

The tests you ran actually exercised the changed code path. A test suite that
passes because it does not cover the change is not a pass. Confirm coverage
before claiming the task is done.