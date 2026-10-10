# EVT Parameters

The exact parameter values for the Peaks-Over-Threshold procedure.

## 1. Threshold

| Parameter | Value | Rationale |
|---|---|---|
| Threshold quantile | 95th percentile | Balances bias and variance |
| Minimum exceedances | 50 | Below this, GPD fit is unstable |

The threshold is **always** the 95th percentile of the calibrated
residual distribution for that ticker and horizon. It is not a fixed
number, because residual scales differ across tickers and horizons.

## 2. GPD Fitting

| Parameter | Value |
|---|---|
| Estimation method | Maximum likelihood (MLE) |
| Location | Fixed at 0 (exceedances are already `x - u`) |
| Shape prior | None |
| Scale prior | None |

The GPD is the 2-parameter version: scale `σ` and shape `ξ`. The
location is 0 because we model exceedances above the threshold, not the
raw residual.

## 3. Exceedance Direction

| Tail | Threshold | Exceedances |
|---|---|---|
| Lower | 5th percentile of residuals | `u - residual` for `residual < u` |
| Upper | 95th percentile of residuals | `residual - u` for `residual > u` |

Both tails are modeled as positive exceedances. The lower tail uses
`u - residual` (which is positive when `residual < u`), so the same GPD
machinery applies.

## 4. Quantile Extrapolation

For a target probability `p` (e.g., `p = 0.01` for the 1st percentile):

    q_p = u + (σ / ξ) × ((n / N_u) × (1 - p))^(-ξ) - 1

If `ξ = 0`, the formula reduces to:

    q_p = u + σ × ln((n / N_u) × (1 - p))

Where:
- `u` is the threshold
- `σ` is the GPD scale
- `ξ` is the GPD shape
- `n` is the total number of residuals
- `N_u` is the number of exceedances
- `p` is the target probability

For the **lower tail**, the same formula is applied to the exceedances
`u - residual`, then the result is negated to return to the residual
scale.

## 5. Fallback Rules

| Condition | Action |
|---|---|
| `N_u < 50` | Fall back to empirical quantile, log WARN |
| `|ξ| < 0.01` | Use exponential GPD (`ξ = 0`), log WARN |
| `ξ > 0.5` | Fit is valid but heavy; log WARN |
| MLE does not converge | Fall back to empirical quantile, log FAIL |

## 6. What Is Not Tuned

- **The 95th percentile threshold.** Fixed.
- **The 50-exceedance minimum.** Fixed.
- **The MLE estimator.** Fixed (PWM/L-moments are alternatives but not
  the default).
- **The GPD family.** Fixed (2-parameter GPD, location = 0).

If a tuning pass wants to change one of these, it is a skill amendment.