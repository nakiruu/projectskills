# Calibration Procedure

The step-by-step TCP calibration algorithm, per ticker, per horizon, per
forecast date.

## 1. Inputs

For a given forecast origin `t`, ticker `i`, and horizon `H`:

- `gspqr_predictions.parquet` — raw quantiles `q_05`, `q_95` for `i` at
  all dates in the calibration window
- `prices.parquet` — realized returns for the same dates

The realized return for a calibration date `s` and horizon `H` is the
forward return from `s` to `s + H`. This requires that `s + H <= t`, which
the window `[t-m, t-1]` guarantees when `m = 60` and `H <= 252` only if
`m >= H`. For `H = 252` and `m = 60`, this is **not** satisfied.

**This is a critical issue.** For horizons longer than the calibration
window, the conformity scores cannot be computed directly because the
forward returns are not yet realized. There are three options:

1. **Extend the calibration window for long horizons.** Use `m = H` for
   horizon `H`. For `H = 252`, this means `m = 252`, which leaves no
   training window.

2. **Use a shorter proxy horizon for long horizons.** Compute the
   conformity scores on the 63-day horizon and apply them to the 252-day
   interval, scaled by `sqrt(252/63)`.

3. **Use a different calibration scheme for long horizons.** The TCP
   paper's rolling window assumes `m >= H`. For long horizons, the
   pipeline uses option 2 as a practical compromise.

**Decision:** The pipeline uses **option 2**. The 63-day conformity
scores are scaled by `sqrt(H/63)` to approximate the longer-horizon
scores. This is an approximation, documented here, and flagged for
future improvement if coverage on the 252-day horizon deviates.

## 2. The Algorithm (per ticker, per horizon)

```
Inputs: ticker i, horizon H, forecast date t, parameters (m, α, γ_0)

1. Determine the calibration window: dates = [t-m, t-1]
2. For each date s in the window:
   a. Read q_05(i, s, H) and q_95(i, s, H) from gspqr_predictions
   b. Read realized return y(i, s, H) from prices
      - For H = 63: y = forward 63-day return from s
      - For H = 126: y = forward 126-day return from s
      - For H = 252: use scaled 63-day residuals (see §1)
   c. Compute score: s_k = max(q_05 - y, y - q_95, 0)
3. Sort the m scores: s_(1) <= s_(2) <= ... <= s_(m)
4. Compute k = ceil((m + 1) * (1 - α))
5. Q_hat = s_(k) if k <= m, else s_(m)
6. Apply Robbins-Monro offset:
   - If TCP-RM enabled: Q_hat = Q_hat + C_t
   - Else: Q_hat = Q_hat
7. Compute calibrated interval:
   - q_hat_lower = q_05(i, t, H) - Q_hat
   - q_hat_upper = q_95(i, t, H) + Q_hat
8. Write to tcp_calibration.parquet
9. Update C_{t+1} = C_t + γ_t * e_t
   - e_t = 1{y(i, t, H) not in [q_hat_lower, q_hat_upper]} - α
   - γ_t = γ_0 / sqrt(t + 1)
   - Clip C_{t+1} to [-0.5, 0.5]
```

## 3. Zero-Truncation

The `max(..., 0)` in step 2c is the zero-truncation. Without it, a
calibration observation where `y` is inside the raw interval would
contribute a negative score, which would lower the conformal quantile
and cause interval contraction.

The TCP paper uses zero-truncated CQR scores for this reason .
The truncation ensures that the conformal quantile only grows when the
raw interval fails to cover.

## 4. Per-Ticker vs Pooled

**Current pipeline: per-ticker.** Each ticker has its own calibration
window and its own `Q̂`. This means a high-volatility ticker gets a wider
`Q̂` and a low-volatility ticker gets a narrower one.

**Alternative: pooled.** A single `Q̂` is computed across all tickers in
the universe on each date. This is more stable but ignores
ticker-specific volatility.

The pipeline uses per-ticker because the GSPQR raw intervals already
adjust for ticker-specific volatility via the features. The TCP layer
adds the residual correction, which should also be ticker-specific.

If a ticker has fewer than `m` valid calibration observations (e.g.,
recently added to the universe), the conformal quantile falls back to
the universe-pooled `Q̂` for that date. This is documented in the code
and logged as a `WARN` in `data_quality.parquet`.

## 5. Coverage Update (Robbins-Monro)

After the interval for `t` is produced and the realized return
`y(i, t, H)` becomes available (at `t + H`), the coverage error is
computed and the offset is updated. This means the offset at date `t`
reflects coverage errors from dates up to `t - H`.

For horizons longer than the calibration window, the offset update also
uses the scaled 63-day residual. This is consistent with the scaling
approach in §1.

## 6. What Not to Do

- Do not include the forecast date `t` in the calibration window.
- Do not use a static calibration set from the beginning of the data.
- Do not skip the zero-truncation.
- Do not use a fixed learning rate for Robbins-Monro.
- Do not pool the calibration across horizons. Each horizon has its own
  calibration scores.
- Do not forget to clip the Robbins-Monro offset.

## 7. Verification

- [ ] A test with synthetic data and known coverage produces the
      expected `Q̂`
- [ ] A test asserts the calibration window is `[t-m, t-1]`
- [ ] A test asserts scores are zero-truncated
- [ ] A test asserts the Robbins-Monro update uses `γ_0 / sqrt(t)`
- [ ] A test asserts the offset is clipped to `[-0.5, 0.5]`
- [ ] Empirical coverage on a held-out period is within ±2pp of nominal