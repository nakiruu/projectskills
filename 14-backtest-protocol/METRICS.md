# Evaluation Metrics

The metrics reported by the backtest protocol, their definitions, and
their interpretation.

## 1. Coverage

    coverage = mean(1{y_t ∈ [q_hat_lower_t, q_hat_upper_t]})

The fraction of test observations where the realized return falls
within the TCP-calibrated interval.

**Target:** 0.95 ± 0.02 at the nominal 95% level. Deviation beyond ±2
percentage points indicates miscalibration.

## 2. Winkler Score

    Winkler = width + (2/α)·(lower − y)·1{y < lower} + (2/α)·(y − upper)·1{y > upper}

Where `width = upper − lower` and `α = 0.05`. Lower is better.
The Winkler score rewards narrow intervals and penalizes violations.

## 3. Pinball Loss

    pinball(y, q̂_τ, τ) = τ·(y − q̂_τ) if y ≥ q̂_τ
                        (1−τ)·(q̂_τ − y) if y < q̂_τ

Averaged over τ ∈ {0.05, 0.50, 0.95}. Lower is better. Measures quantile
forecast accuracy.

## 4. CRPS

Continuous Ranked Probability Score. Measures the distance between the
predicted distribution and the realized value. Lower is better. CRPS
generalizes pinball loss to the full distribution.

## 5. Sortino Ratio

    Sortino = (mean(R_p) − R_target) / σ_downside

Where `σ_downside` is the lower semi-deviation below `R_target`. Higher
is better. This is the primary return metric because the optimizer
maximizes it.

## 6. Max Drawdown

    MDD = max_t (peak_t − trough_t) / peak_t

The worst peak-to-trough decline. Lower is better. Reported as a
negative percentage.

## 7. Sharpe Ratio

    Sharpe = (mean(R_p) − R_f) / std(R_p)

Higher is better. Reported alongside the Deflated Sharpe Ratio when the
trial count `N` is known.

## 8. Reporting Format

All metrics are reported as a **distribution** across CPCV paths:

| Metric | Mean | Std | 5th pctile | 50th pctile | 95th pctile |
|---|---|---|---|---|---|
| Coverage | 0.947 | 0.012 | 0.928 | 0.948 | 0.965 |
| Winkler | 0.512 | 0.041 | 0.448 | 0.509 | 0.582 |
| Pinball | 0.041 | 0.005 | 0.034 | 0.041 | 0.049 |
| Sortino | 1.12 | 0.24 | 0.78 | 1.10 | 1.48 |
| MDD | −0.18 | 0.04 | −0.24 | −0.17 | −0.12 |

A single mean without the distribution is not reported. The distribution
is the result.

## 9. What Not to Do

- Do not report a single Sharpe ratio from a single path.
- Do not report coverage without the interval width. Wide intervals
  trivially achieve coverage.
- Do not compare metrics across different CPCV configurations. The
  parameters are fixed.
- Do not report the DSR without the trial count `N`.