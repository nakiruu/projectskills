# TCP Parameters

The exact parameter values, their rationale, and their tuning ranges.

## 1. Window Sizes

| Parameter | Symbol | Value | Rationale |
|---|---|---|---|
| Total lookback | `w` | 252 trading days | 1 year. Matches the longest horizon (252d). |
| Calibration window | `m` | 60 trading days | 3 months. Long enough for stable quantiles, short enough to adapt. |
| Train window | `w - m` | 192 trading days | Residual after subtracting calibration. |

**Why `m = 60`:** With `m = 60` and `α = 0.05`, the order statistic is
`k = ceil((60+1) × 0.95) = 58`. This is the 58th smallest of 60 scores.
Stable enough to avoid noise, but responsive enough to shift within a
quarter.

**Why `w = 252`:** The longest forward horizon is 252 trading days.
Using a lookback shorter than the horizon would mean the calibration
window includes dates whose forward returns are not yet realized at the
forecast origin. `w = 252` ensures full realization.

## 2. Miscoverage Rate

| Parameter | Symbol | Value |
|---|---|---|
| Nominal coverage | `1 - α` | 0.95 |
| Miscoverage | `α` | 0.05 |

The pipeline produces 95% intervals by default. A separate 80% interval
(α = 0.20) can be produced by running TCP with a different α and writing
to a different output file, but the pipeline does not do this by default.

## 3. Order Statistic

    k = ceil((m + 1) × (1 - α))

For `m = 60`, `α = 0.05`: `k = ceil(61 × 0.95) = ceil(57.95) = 58`.

The conformal quantile `Q̂` is the `k`-th smallest of the `m` conformity
scores. If `k > m`, use the largest score. If `m = 0`, the interval is
the raw GSPQR interval (no calibration).

## 4. Robbins-Monro Schedule

TCP-RM adds an online offset `C_t` to the conformal threshold. The
update rule:

    C_{t+1} = C_t + γ_t × e_t

Where:
- `e_t = 1{y_t ∉ [q_hat_lower_t, q_hat_upper_t]} - α` (coverage error)
- `γ_t = γ_0 / sqrt(t + 1)` (decaying learning rate)

Parameters:

| Parameter | Symbol | Value | Rationale |
|---|---|---|---|
| Initial learning rate | `γ_0` | 0.01 | Small enough to avoid oscillation |
| Decay | `1 / sqrt(t)` | — | Satisfies Robbins-Monro conditions |
| Initial offset | `C_0` | 0.0 | Start with no adjustment |
| Offset clip | — | `[-0.5, 0.5]` | Prevent runaway in extreme regimes |

The Robbins-Monro conditions (`∑γ_t = ∞`, `∑γ_t² < ∞`) are satisfied by
`γ_t = γ_0 / sqrt(t)` [citation:3]. The offset converges to the value
that makes empirical coverage equal to nominal.

**When to disable TCP-RM:** If the coverage error is already near zero
on the validation set, the offset adds noise without benefit. Disable
by setting `γ_0 = 0.0`. The pipeline defaults to enabled because
financial time series are non-stationary by nature.

## 5. Tuning Ranges

If coverage deviates from nominal by more than 2 percentage points:

| Symptom | Adjust |
|---|---|
| Over-coverage (coverage > α + 0.02) | Reduce `m` (faster adaptation) or increase `γ_0` |
| Under-coverage (coverage < α - 0.02) | Increase `m` (more stable threshold) or reduce `γ_0` |
| Wide intervals, correct coverage | Reduce `m` if the market is stable, increase if volatile |
| Oscillating offset | Reduce `γ_0` by half |

**Do not tune `α`.** It is the target coverage, not a free parameter.
Changing it changes what the interval means.

## 6. What Is Not Tuned

- **The zero-truncation of scores.** Always truncated.
- **The rolling window structure.** Always rolling, never static.
- **The Robbins-Monro update form.** Always `C_{t+1} = C_t + γ_t e_t`.
- **The point-in-time rule.** Calibration is always `[t-m, t-1]`.

If a tuning pass wants to change one of these, it is a skill amendment.