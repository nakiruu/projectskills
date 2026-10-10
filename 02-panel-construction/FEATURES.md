# Feature Formulas

Every raw feature, its exact computation, its edge cases, and its
verification test.

Notation: `close[t]` is the adjusted close on trading day `t`. `volume[t]`
is the share volume. `shares_outstanding[t]` is from the most recent
filing with `filing_date <= t`. `revenue_ttm[t]` is trailing-twelve-month
revenue from the most recent filing with `filing_date <= t`.

---

## 1. Momentum Features

### `mom_20d`

    20-day return: close[t] / close[t-20] - 1

**Edge cases:**
- If `close[t-20]` is NaN, the feature is NaN.
- If fewer than 21 days of history, NaN.

### `mom_60d`

    60-day return: close[t] / close[t-60] - 1

Same edge cases.

### `mom_12m_1m`

    12-month return skipping the most recent month:
    close[t-21] / close[t-252] - 1

The skip-1-month convention avoids contaminating momentum with short-term
reversal, which is a well-documented effect (Jegadeesh 1990, Asness 2013).

**Edge cases:**
- Requires 253 trading days of history. NaN below that.
- If `close[t-252]` is NaN, NaN.

---

## 2. Volatility Feature

### `vol_60d_res`

Residual volatility from a rolling regression of daily returns on the
equal-weighted universe return over a 60-day window.

**Procedure:**

For each date `t`, for each ticker `i`:

1. Take the last 60 daily returns of `i`:
   `r_i[t-59:t]` (60 values).
2. Take the last 60 daily returns of the equal-weighted universe:
   `r_mkt[t-59:t]`.
3. Fit `r_i = α + β · r_mkt + ε` via OLS.
4. `vol_60d_res[t] = std(ε) × sqrt(252)`.

**Why residual (not raw):** Raw volatility captures both market and
idiosyncratic variance. The GSPQR paper uses residual volatility to
isolate the stock-specific risk component, which is the one that predicts
cross-sectional returns.

**Edge cases:**
- Requires at least 40 valid return pairs in the 60-day window. Below
  that, NaN.
- If all returns are identical (zero variance), NaN.

**Verification:** Regress a synthetic series with known β and residual
std on a synthetic market, confirm `vol_60d_res` matches within 1e-6.

---

## 3. Valuation Feature

### `sp_ratio`

    Sales-to-price = revenue_ttm[t] / market_cap[t]
    market_cap[t] = close[t] × shares_outstanding[t]

**Point-in-time discipline:**
- `revenue_ttm[t]` uses the most recent 10-Q or 10-K with
  `filing_date <= t`.
- `shares_outstanding[t]` uses the same filing.
- The join is an as-of join on `filing_date`.

**Edge cases:**
- If no filing exists before `t`, NaN.
- If `revenue_ttm` is negative or zero, NaN (the ratio is meaningless).
- If `market_cap` is NaN, NaN.

**Verification:** Take a known filing and price, compute by hand,
compare.

---

## 4. Liquidity Feature

### `turn_20d`

    20-day mean turnover:
    mean(volume[t-19:t] / shares_outstanding[t-19:t])

Each day's turnover uses that day's shares outstanding (from the most
recent filing before that day). The mean is over the trailing 20 days.

**Edge cases:**
- If any day in the window has NaN volume or shares, that day is skipped
  and the mean is over the valid days. Requires at least 15 valid days.
- Below 15 valid days, NaN.

**Verification:** Take a known 20-day window, compute the mean of daily
turnover ratios, compare.

---

## 5. Z-Score Normalization

Before features enter GSPQR, each is normalized via a rolling 60-day
Z-score:

    z_feat[t] = (feat[t] - mean(feat[t-59:t])) / std(feat[t-59:t])

**Why rolling, not expanding:** Expanding windows use all history, which
means the normalized value at date `t` depends on data from before `t`
in a way that is not point-in-time stable. Rolling windows use only the
trailing 60 days.

**Edge cases:**
- If std is zero or NaN, the Z-score is NaN.
- If fewer than 40 valid values in the window, NaN.

**Note:** The Z-scored features are intermediate. They feed the rank
computation but are not stored in the panel. Only the raw and rank
features are stored. If you need the Z-scores for debugging, recompute
them from the raw features.

---

## 6. What Is Not a Feature

- **No lagged returns beyond the momentum windows.** Adding
  `ret_1d`, `ret_5d`, etc. would duplicate `mom_20d` information.
- **No technical indicators.** RSI, MACD, Bollinger Bands are not in the
  GSPQR feature set. Adding them requires a skill amendment and a
  backtest proving incremental value.
- **No fundamental ratios beyond `sp_ratio`.** P/E, P/B, EV/EBITDA are
  used in the conviction overlay, not in GSPQR. Do not add them here.
- **No macro features in the panel.** Macro enters via the regime
  module and the HANET-style attention if implemented. The panel is
  cross-sectional only.

If you believe a feature is missing, propose it as a skill amendment
with a backtest. Do not add it silently.

---

## 7. Feature Ordering

The 12 features are stored in this exact order in `panel.parquet`:

    mom_20d, mom_60d, mom_12m_1m, vol_60d_res, sp_ratio, turn_20d,
    r_mom_20d, r_mom_60d, r_mom_12m_1m, r_vol_60d, r_sp, r_turn

The GSPQR feature matrix uses this order. Reordering breaks the model's
feature-name binding. The linter enforces this order via the schema
hash.

---

## 8. Verification Summary

| Feature | Test |
|---|---|
| `mom_20d` | Recompute from known closes, compare |
| `mom_60d` | Same |
| `mom_12m_1m` | Same, with 1-month skip |
| `vol_60d_res` | Synthetic regression with known β and σ |
| `sp_ratio` | Hand-compute from a real filing |
| `turn_20d` | Hand-compute from a real 20-day window |
| Z-scores | Verify rolling window, not expanding |
| Ranks | Verify NaN below 50 names |

Every feature has a test. The test file is `tests/features.jl`. No
feature is considered implemented until its test passes.