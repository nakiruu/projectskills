---
name: evt-tails
description: Extreme Value Theory tail extension for calibrated residuals.
  Load when touching evt/, GPD fitting, tail quantiles, or extreme bounds.
---

# EVT Tail Extension

TCP produces calibrated 5%/95% bounds. EVT extends those to 1%/99%
using Extreme Value Theory. This skill documents the Peaks-Over-Threshold
(POT) procedure, the Generalized Pareto Distribution (GPD) fit, and the
extreme quantile extrapolation.

## 1. What EVT Produces

For each ticker, fit date, and horizon, two outputs per tail:

| Output | Meaning |
|---|---|
| `gpd_shape_xi` | GPD shape parameter (tail heaviness) |
| `gpd_scale_sigma` | GPD scale parameter |
| `q_extreme` | The 1st or 99th percentile bound |

The `evt_tail_bounds.parquet` schema (see `13-parquet-lake/SCHEMAS.md`
§10) stores these with one row per `(ticker, fit_date, horizon, tail)`.

## 2. Why EVT Over Just Using More Quantiles

You could ask GSPQR for the 1st and 99th percentiles directly. LightGBM
supports any quantile level. Why add EVT?

**Reason 1: Data scarcity.** The 1st percentile is defined by 1% of the
training sample. With 10,000 training rows, that is 100 observations. The
GPD fit uses **all exceedances above the 95th percentile** (500 rows in
the same sample), which is 5× more data. The tail shape is estimated
from the exceedance distribution, not from the extreme quantile alone.

**Reason 2: Extrapolation.** EVT provides a principled way to extrapolate
beyond observed quantiles. The GPD quantile formula extrapolates into the
tail where empirical quantiles become unstable. LightGBM's quantile
regression is non-parametric and cannot extrapolate.

**Reason 3: Theoretical grounding.** The Pickands-Balkema-de Haan theorem
guarantees that exceedances above a high threshold converge to a GPD for
a broad class of distributions [citation:6][citation:17]. This is the
EVT analogue of the Central Limit Theorem.

## 3. The POT Procedure

See `EVT-PROCEDURE.md` for the full algorithm. The summary:

1. **Compute calibrated residuals** from the TCP layer:
   `residual = realized_return - calibrated_mid`
2. **Select a threshold** at the 95th percentile of residuals.
3. **Extract exceedances**: `z_j = residual_j - u` for all `residual_j > u`.
4. **Fit a GPD** to the exceedances via maximum likelihood.
5. **Extrapolate** to the 1st/99th percentile using the GPD quantile
   formula.

## 4. Threshold Selection

The threshold `u` is the 95th percentile of calibrated residuals. This
is not tuned. The rationale:

- 95% gives enough exceedances (5% of the sample) for a stable GPD fit.
- 95% is high enough that the GPD approximation holds.
- 95% is the same level as the TCP interval bounds, so the EVT layer
  extends the same exceedance region.

**If fewer than 50 exceedances:** the GPD fit is unstable. The pipeline
logs a `WARN` and falls back to the empirical 1st/99th percentile of the
calibrated residuals. The `q_extreme` is still produced, but flagged.

## 5. GPD Parameter Estimation

Maximum likelihood (MLE) is the default. The `scipy.stats.genpareto`
implementation (via Python interop) or a native Julia GPD MLE routine
is used.

**Why MLE despite known issues:** MLE is the standard estimator. It has
theoretical efficiency guarantees and is implemented in every statistics
library. Alternatives (PWM, L-moments) can outperform MLE in small
samples [citation:19], but the 50-exceedance minimum mitigates the small
sample problem.

**Known limitation:** MLE for GPD can be numerically difficult when the
shape parameter is near 0 or when exceedances are sparse [citation:17].
The pipeline monitors the fitted shape parameter and logs a `WARN` if
`|xi| < 0.01` (near-exponential tail) or `xi > 0.5` (very heavy tail).

## 6. What Not to Do

- Do not fit the GPD to raw returns. It is fit to **calibrated residuals**
  from TCP. See `EVT-PROCEDURE.md` §1.
- Do not use a threshold below the 95th percentile. The GPD approximation
  degrades for lower thresholds.
- Do not fit a single GPD to both tails. Left and right tails are fit
  separately with their own thresholds.
- Do not extrapolate beyond the 1st/99th percentile. The GPD fit is valid
  for the exceedance region, not for the extreme far tail (0.1%, 0.01%).
- Do not skip the exceedance count check. Below 50, fall back to empirical.
- Do not ignore the shape parameter. A shape near 0 or above 0.5 indicates
  the tail model may not fit well.

## 7. Verification

Before deploying an EVT change:

- [ ] A test on synthetic Pareto data recovers the known shape parameter
      to within 10%
- [ ] A test asserts the threshold is the 95th percentile of residuals
- [ ] A test asserts the fallback to empirical when exceedances < 50
- [ ] `evt_tail_bounds.parquet` schema matches the registry
- [ ] A test asserts left and right tails are fit separately

## 8. Related Skills

- `04-tcp-calibration` — provides calibrated residuals
- `03-gspqr-model` — provides the raw quantiles that TCP calibrates
- `13-parquet-lake` — schema for `evt_residuals` and `evt_tail_bounds`
- `14-backtest-protocol` — evaluates tail coverage