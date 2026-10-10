# Forward Return Targets

The prediction targets. Three horizons, each a cumulative excess return.

## 1. Definition

For a forecast origin at date `t`, the H-day forward excess return is:

    y_fwd_Hd[t] = (close[t+H] / close[t] - 1) - rf[t, t+H]

Where `rf[t, t+H]` is the cumulative risk-free return over the same
period. The risk-free rate is from FRED `DGS3MO` (3-month T-bill),
converted to a cumulative return over H trading days:

    rf[t, t+H] = (1 + DGS3MO[t]/100)^(H/252) - 1

If `DGS3MO[t]` is NaN, use the most recent prior value. If none, the
target is NaN.

## 2. Horizons

| Column | H (trading days) | Approx. calendar |
|---|---|---|
| `y_fwd_63d` | 63 | 3 months |
| `y_fwd_126d` | 126 | 6 months |
| `y_fwd_252d` | 252 | 12 months |

The three horizons are stored independently. A row can have a valid
`y_fwd_63d` and NaN `y_fwd_252d` if the 252-day window extends past the
last available price.

## 3. NaN Rules

**A target is NaN if and only if:**

- `close[t+H]` is NaN or the date `t+H` is beyond the ticker's last
  available price.
- The ticker was delisted, merged, or otherwise removed from the universe
  between `t` and `t+H`.

**A target is NOT NaN because:**

- The feature at `t` is NaN. Features and targets are independent.
- The ticker was not in the universe at `t` but is at `t+H`. Universe
  membership is separate from target availability.

Do not impute targets. Do not drop rows with NaN targets. GSPQR is
trained only on rows where the target for the horizon being modeled is
non-NaN.

## 4. Train / Cal / Test Split

The `split` column is assigned per ticker, chronologically:

    1. Sort the ticker's rows by date.
    2. Let N = number of rows.
    3. Rows [1, 0.6N] are `train`.
    4. Rows (0.6N, 0.8N] are `cal`.
    5. Rows (0.8N, N] are `test`.

Rounding: `floor(0.6N)` for the train boundary, `floor(0.8N)` for the
cal boundary.

**Why per-ticker, not global:** A global split would leave some tickers
entirely in `test` if they IPO'd late. Per-ticker ensures every ticker
contributes to every phase, which matters for cross-sectional rank
features.

**Effect on overlapping horizons:** A row near the `train`/`cal`
boundary may have a 252-day forward return that overlaps with rows in
`cal`. This is expected. The TCP calibration handles overlapping horizons
via HAC errors (see `04-tcp-calibration` and `14-backtest-protocol`).

## 5. The Forecast Origin Boundary

The `split` column is not the same as the TCP forecast origin. TCP rolls
its own training and calibration windows at each forecast date. The
`split` column is used only for:

- Model training (GSPQR trains on `split = train`)
- Backtest evaluation (metrics computed on `split = test`)

The TCP calibration window at forecast origin `t` is:

    train: dates in [t - w, t - m - 1]
    cal:   dates in [t - m, t - 1]

where `w = 252` and `m = 60`. This is independent of the `split` column.

A ticker in `test` phase may still contribute to TCP's rolling window if
the forecast origin is late enough. Do not conflate the two concepts.

## 6. Survivorship Bias

The panel includes tickers that were in the universe on each date. A
ticker that was delisted in 2022 has rows through its last trading day,
then no more. The panel does NOT retroactively remove it from 2021.

This is correct. A backtest that uses the panel as-is reproduces the
historical opportunity set: at each date, you could only trade what
existed.

**Do not** rebuild the panel using only currently-listed tickers. That
introduces survivorship bias and inflates backtest returns.

## 7. What Not to Do

- Do not compute forward returns using unadjusted close prices. Use
  `adj_close` throughout.
- Do not use the raw risk-free rate. Convert to a cumulative return over
  the horizon.
- Do not drop rows with NaN targets. They are legitimate rows with
  unknown future.
- Do not reassign `split` after the panel is built. The split is
  immutable for a given panel version.
- Do not use the `split` column for TCP. TCP rolls its own windows.

## 8. Verification

- [ ] A test recomputes `y_fwd_63d` from known prices and risk-free rate
- [ ] A test asserts NaN beyond the horizon
- [ ] A test asserts the split boundaries match the 60/20/20 rule
- [ ] A test asserts no ticker is entirely in one split (unless it has
      fewer than 5 rows)
- [ ] A test asserts that delisted tickers retain their historical rows