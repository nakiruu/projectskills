---
name: tcp-calibration
description: Temporal Conformal Prediction for GSPQR quantiles. Load when
  touching calibration/tcp/, conformity scores, rolling windows, or the
  Robbins-Monro offset.
---

# TCP Calibration

TCP wraps GSPQR. It does not change the base model. It reads the raw
quantiles from `gspqr_predictions.parquet`, computes conformity scores on
a rolling calibration window, and produces calibrated interval bounds
written to `tcp_calibration.parquet`.

## 1. What TCP Produces

For each ticker, forecast date, and horizon:

| Output | Meaning |
|---|---|
| `q_hat_lower` | Calibrated 5% lower bound |
| `q_hat_upper` | Calibrated 95% upper bound |
| `rm_offset` | Robbins-Monro offset applied (0.0 if TCP-RM disabled) |
| `calib_width` | `q_hat_upper - q_hat_lower` |

The calibrated interval is:
- `q_hat_lower = q_05 - Q̂`
- `q_hat_upper = q_95 + Q̂`

Where `Q̂` is the conformal quantile of the calibration scores (or the
Robbins-Monro adjusted threshold in TCP-RM).

## 2. The Two Variants

**TCP (standard).** Rolling split-conformal calibration. At each forecast
origin, the calibration window is a rolling set of the most recent `m`
observations. The conformal threshold is the empirical quantile of the
conformity scores in that window.

**TCP-RM.** TCP plus an online Robbins-Monro offset. The offset adjusts
the conformal threshold based on recent coverage error, using a decaying
learning rate that satisfies the Robbins-Monro conditions
(`∑γ_t = ∞`, `∑γ_t² < ∞`). This steers the actual coverage toward the
target in real time.

The pipeline uses **TCP-RM by default**. See `PARAMETERS.md` for the
decay schedule.

## 3. Why TCP Over Static CQR

Static CQR (Conformalized Quantile Regression) assumes exchangeability.
Financial time series are not exchangeable — volatility clusters, regimes
shift, and the distribution of returns is not stationary.

TCP addresses this with a **rolling window**. At each forecast origin,
the calibration set is the most recent `m` observations, not a fixed
split from the beginning of the data. This means the conformal threshold
adapts to the current volatility regime.

Empirical results from the TCP paper: TCP attains 95.23% coverage on the
S&P 500 at a 95% nominal level, with intervals that expand during the
COVID-19 crash and contract during calm periods. Static QR over-covers
(produces intervals that are too wide) because it cannot adapt
[citation:1].

## 4. Conformity Scores

See `CALIBRATION.md` for the exact formulas. The summary:

For a calibration observation with realized return `y` and raw GSPQR
quantiles `q_05` and `q_95`:

    s_lower = q_05 - y        (if y < q_05, else 0)
    s_upper = y - q_95        (if y > q_95, else 0)
    score   = max(s_lower, s_upper)

The score is **zero-truncated**: observations inside the raw interval
contribute zero. This prevents the conformal threshold from being
dominated by observations that are already well-covered. The TCP paper
uses a zero-truncated CQR score for this reason [citation:1].

## 5. The Rolling Window

At forecast origin `t`:

    Train window:    dates in [t - w, t - m - 1]
    Cal window:      dates in [t - m, t - 1]

Where `w = 252` (1 year) and `m = 60` (3 months). The train window is
used to refit GSPQR if the calibration is done jointly (which it is not
in the current pipeline — GSPQR is trained monthly, TCP calibrates daily).
The cal window is used to compute conformity scores.

**Critical:** the calibration window is strictly prior to `t`. No
observation at `t` or later enters the calibration for forecast origin
`t`. This is the point-in-time requirement (constitution §3).

## 6. What Not to Do

- Do not use a static calibration split. TCP requires a rolling window.
- Do not include the forecast origin date in the calibration window.
  It is `[t-m, t-1]`, not `[t-m, t]`.
- Do not use non-zero-truncated scores. The truncation prevents
  interval contraction.
- Do not update the Robbins-Monro offset with a fixed learning rate.
  Use the decaying schedule (`η_t = η_0 / sqrt(t)`).
- Do not calibrate per-ticker in isolation. The conformity scores are
  computed on the ticker's own history, but the window is shared across
  the horizon. See `CALIBRATION.md` §4.
- Do not overwrite `tcp_calibration.parquet`. Append to the current
  partition, atomic rename.

## 7. Verification

Before deploying a calibration change:

- [ ] The calibration window is strictly prior to the forecast date
- [ ] Conformity scores are zero-truncated
- [ ] The Robbins-Monro offset uses the decaying schedule
- [ ] Empirical coverage on a held-out period is within ±2 percentage
      points of nominal
- [ ] Interval width is narrower than a static CQR baseline on the same
      data
- [ ] `tcp_calibration.parquet` schema matches the registry

## 8. Related Skills

- `03-gspqr-model` — provides the raw quantiles
- `05-evt-tails` — consumes the calibrated residuals
- `13-parquet-lake` — schema for `tcp_calibration.parquet`
- `14-backtest-protocol` — evaluates coverage