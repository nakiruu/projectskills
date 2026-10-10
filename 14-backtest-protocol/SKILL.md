---
name: backtest-protocol
description: Walk-forward evaluation with purged cross-validation.
  Load when touching backtest/, evaluation/, performance metrics, or
  any code that scores the system on historical data.
---

# Backtest Protocol

The backtest is the only honest measure of whether the system works.
Every other skill builds the system. This skill evaluates it.

## 1. The Core Problem

Financial time series are not exchangeable. Standard k-fold
cross-validation — shuffling observations into random folds — leaks
future information into the training set and produces inflated
performance estimates [citation:14].

Walk-forward analysis addresses this by training on the past and testing
on the future. But simple walk-forward has its own problem: the
estimated Sharpe ratio has high variance because a large portion of the
decisions are based on a small portion of the dataset, and a few
observations carry outsized weight [citation:17].

## 2. The Protocol

The pipeline uses **Combinatorial Purged Cross-Validation (CPCV)**,
introduced by López de Prado [citation:12][citation:16]. CPCV:

1. Partitions the timeline into `N` contiguous groups.
2. For each combination of `k` test groups, trains on the remaining
   `N-k` groups.
3. Applies **purging** (removes training observations whose label
   overlaps the test period) and **embargoing** (removes training
   observations immediately after the test period to account for serial
   correlation) [citation:12].
4. Generates multiple backtest paths by reconstructing the full
   timeline from each combination.

The result is a **distribution** of performance metrics across paths,
not a single point estimate. This directly addresses the high variance
of walk-forward [citation:17].

## 3. Parameters

| Parameter | Value | Rationale |
|---|---|---|
| `N` (total groups) | 10 | Standard from López de Prado examples |
| `k` (test groups per fold) | 8 | Produces 45 training combinations, 36 paths |
| Purge period | 21 days | One business month; exceeds the longest forecast horizon overlap |
| Embargo period | 21 days | One business month; removes serial correlation bleed |
| Train/validation split within train | 80/20 | For early stopping |

These parameters match those used in the Hopfield Networks for Asset
Allocation paper, which used 10 training folds and 8 test folds,
resulting in 36 backtest paths and 45 training combinations, with 21-day
purge and embargo windows [citation:16].

## 4. Evaluation Metrics

See `METRICS.md`. The pipeline reports:

- **Coverage**: empirical coverage of TCP-calibrated intervals
- **Winkler Score**: interval sharpness
- **Pinball Loss**: quantile forecast accuracy
- **CRPS**: distributional forecast accuracy
- **Sortino Ratio**: downside-adjusted return
- **Max Drawdown**: worst peak-to-trough decline
- **Sharpe Ratio**: risk-adjusted return

Each metric is reported as a **distribution** across all CPCV paths
(mean, standard deviation, percentiles), not a single number.

## 5. Walk-Forward vs CPCV

See `WALK-FORWARD.md` for the simple walk-forward variant, which is used
for **early stopping during training** (not final evaluation). CPCV is
used for **final evaluation** because it produces multiple paths and a
distribution of metrics [citation:17].

The `WalkForwardEstimator` in `PortfolioOptimisers.jl` supports a
`purged_size` parameter (default 5) for the pre-test boundary [citation:4].
The pipeline uses this for the model training loop, not for the final
backtest.

## 6. Implementation

See `scripts/run-backtest.jl`. The backtest:

1. Loads the full panel with `split` column.
2. Uses `DataSplits.PurgedKFold` or equivalent for CPCV folds [citation:19].
3. For each fold, trains GSPQR on the training portion.
4. Applies TCP calibration on the training portion (rolling).
5. Applies EVT on calibrated residuals.
6. Runs the portfolio optimizer on the test portion.
7. Applies the lock state machine to gate execution.
8. Computes returns for the test portion.
9. Joins test portions into backtest paths.
10. Computes metrics per path.

**Critical:** The portfolio optimizer and lock state machine must run
**inside** each fold. They cannot be pre-computed on the full dataset,
because the lock state at any date depends on prior decisions within
that path.

## 7. The Deflated Sharpe Ratio

The pipeline reports the Deflated Sharpe Ratio (DSR) alongside the raw
Sharpe [citation:3]. The DSR corrects for the number of trials:

    DSR = Φ((SR_max − E[SR_max]) × √(T−1) / σ_SR)

Where `E[SR_max] ≈ √(2 ln N) / √T` is the expected maximum Sharpe under
the null of zero skill, given `N` trials [citation:3].

**Caveat:** The DSR requires the number of trials `N`. In this pipeline,
`N` is the number of model configurations evaluated during hyperparameter
tuning. The DSR is reported **only when `N` is known and logged**. If
`N` is unknown, the DSR is omitted and the raw Sharpe is reported with
an explicit warning [citation:13].

## 8. What Not to Do

- Do not use standard k-fold cross-validation. It leaks future data.
- Do not shuffle observations. Chronological order is mandatory.
- Do not report a single Sharpe ratio. Report the distribution across
  CPCV paths.
- Do not tune hyperparameters on the test set. Use walk-forward within
  the training portion.
- Do not skip purging. Overlapping label horizons leak information.
- Do not skip embargoing. Serial correlation bleeds across the boundary.
- Do not report the DSR without stating `N`. A DSR without `N` is a
  number with a free parameter [citation:13].

## 9. Verification

- [ ] A test asserts CPCV produces the expected number of paths
- [ ] A test asserts purge removes overlapping training rows
- [ ] A test asserts embargo removes post-test training rows
- [ ] A test asserts metrics are computed per path, not on joined data
- [ ] A test asserts the DSR is only reported when `N` is provided
- [ ] A test asserts the lock state machine runs inside each fold

## 10. Related Skills

- `00-constitution` §3 — no lookahead rule
- `02-panel-construction` — provides the `split` column
- `03-gspqr-model` — the model being evaluated
- `04-tcp-calibration` — calibration inside each fold
- `05-evt-tails` — EVT inside each fold
- `08-portfolio-optimization` — optimizer inside each fold
- `09-lock-state-machine` — lock gating inside each fold