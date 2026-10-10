# EVT Procedure

The step-by-step algorithm for fitting the GPD and extrapolating to
extreme quantiles.

## 1. Input: Calibrated Residuals

EVT operates on **calibrated residuals**, not raw returns.

For a calibration observation at date `s` with horizon `H`:

    calibrated_mid = (q_hat_lower + q_hat_upper) / 2
    residual = realized_return - calibrated_mid

Where `q_hat_lower` and `q_hat_upper` are from `tcp_calibration.parquet`
and `realized_return` is the actual forward return.

The residual measures how far the realized return deviated from the
center of the calibrated interval. If TCP is well-calibrated, residuals
should be roughly symmetric around zero, with fat tails.

## 2. Threshold Selection

For a given ticker and horizon, collect all residuals from the trailing
`W = 252` trading days (or the maximum available if fewer).

    u_upper = quantile(residuals, 0.95)
    u_lower = quantile(residuals, 0.05)

The upper threshold is the 95th percentile of residuals. The lower
threshold is the 5th percentile.

## 3. Exceedance Extraction

For the upper tail:

    z_upper = [r - u_upper for r in residuals if r > u_upper]

For the lower tail:

    z_lower = [u_lower - r for r in residuals if r < u_lower]

Both `z_upper` and `z_lower` contain positive values. The GPD is fit to
each separately.

## 4. GPD Fitting

For each tail, fit a 2-parameter GPD with location 0:

```julia
using Distributions

function fit_gpd(exceedances::Vector{Float64})
    n_u = length(exceedances)
    if n_u < 50
        return nothing  # trigger fallback
    end

    # MLE fit
    # GeneralizedPareto(shape, scale, location=0)
    # Distributions.jl: fit(GeneralizedPareto, exceedances)
    # Note: the location must be fixed at 0, not estimated.
    d = fit(GeneralizedPareto, exceedances; loc = 0.0)
    return (shape = d.ξ, scale = d.σ)
end
```

**Note on `Distributions.jl`:** The `GeneralizedPareto` distribution in
`Distributions.jl` uses the parameterization `(shape, scale, location)`.
The `fit` function estimates all three by default. The pipeline fixes
`location = 0.0` because exceedances are already centered at 0.

If `Distributions.jl`'s fit is unstable (common for GPD), fall back to
`scipy.stats.genpareto.fit` via `PyCall.jl` or a custom MLE routine.

## 5. Quantile Extrapolation

For the upper tail, the 99th percentile of residuals is:

    n = length(residuals)
    n_u = length(z_upper)
    p = 0.99

    q_upper = u_upper + (σ / ξ) * ((n / n_u) * (1 - p))^(-ξ) - 1

For the lower tail, the 1st percentile of residuals is:

    q_lower = u_lower - (σ / ξ) * ((n / n_u) * (1 - p))^(-ξ) - 1

Where `p = 0.01` for the lower tail.

The `q_extreme` stored in `evt_tail_bounds.parquet` is:
- `q_upper` for `tail = "upper"`
- `q_lower` for `tail = "lower"`

## 6. Fallback Procedure

If the GPD fit fails (fewer than 50 exceedances, non-convergence, or
numerical issues):

    q_upper = quantile(residuals, 0.99)
    q_lower = quantile(residuals, 0.01)

The empirical quantile is used directly. The `q_extreme` is still
produced, but the `gpd_shape_xi` and `gpd_scale_sigma` columns are
written as NaN, and a `WARN` is logged.

## 7. Integration with TCP

The EVT bounds are **additional** to the TCP bounds, not replacements.

- TCP provides the 5%/95% interval: `q_hat_lower`, `q_hat_upper`
- EVT provides the 1%/99% bounds: `q_extreme_lower`, `q_extreme_upper`

Downstream modules (portfolio optimizer, risk engine) use the TCP
interval for expected return and downside risk, and the EVT bounds for
extreme scenario analysis and stress testing.

## 8. Verification

- [ ] A test on synthetic Pareto data recovers the shape parameter
- [ ] A test asserts the threshold is the 95th percentile
- [ ] A test asserts exceedances are positive
- [ ] A test asserts the fallback when `N_u < 50`
- [ ] A test asserts the lower tail is negated correctly
- [ ] A test asserts the quantile formula matches the GPD CDF inversion

## 9. What Not to Do

- Do not fit the GPD to raw returns. Use calibrated residuals.
- Do not estimate the location parameter. Fix it at 0.
- Do not pool left and right tails. Fit separately.
- Do not use a threshold other than the 95th percentile without a skill
  amendment.
- Do not skip the fallback when exceedances are insufficient.
- Do not extrapolate beyond the 1st/99th percentile.