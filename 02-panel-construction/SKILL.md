---
name: panel-construction
description: Building the 12-feature panel that feeds GSPQR. Load when
  touching features/, panel/, or any code computing momentum, volatility,
  sales-to-price, turnover, or forward returns.
---

# Panel Construction

The panel is the training and inference matrix. One row per ticker per
trading day. Eighteen columns: three identifiers, three forward-return
targets, six raw features, six cross-sectional rank features.

## 1. What the Panel Contains

The exact schema is in `13-parquet-lake/SCHEMAS.md` §5. The feature
breakdown:

| Group | Columns | Count |
|---|---|---|
| Identifiers | `ticker`, `date`, `split` | 3 |
| Targets | `y_fwd_63d`, `y_fwd_126d`, `y_fwd_252d` | 3 |
| Raw features | `mom_20d`, `mom_60d`, `mom_12m_1m`, `vol_60d_res`, `sp_ratio`, `turn_20d` | 6 |
| Rank features | `r_mom_20d`, `r_mom_60d`, `r_mom_12m_1m`, `r_vol_60d`, `r_sp`, `r_turn` | 6 |

Total: 18 columns. Feature column order is frozen (constitution §5).

## 2. Non-Negotiables

Inherited from the constitution (§2, §3):

- **No feature uses data after `date`.** A feature computed "for date `t`"
  uses prices through `t` and fundamentals with `filing_date <= t`.
- **No random splits.** Train/cal/test assignment is chronological. The
  assignment rule is in `TARGETS.md` §4.
- **No cross-sectional ranks with fewer than 50 names.** Ranks are
  computed per date across the full eligible universe (IWF + IWP ≈ 600
  names, after liquidity filters). Mag7 alone produces ranks 1–7, which
  are not meaningful.
- **NaN is a valid value.** A row where the horizon extends past the last
  available price has NaN targets. Do not forward-fill targets.
- **No dropping rows with NaN features.** GSPQR uses LightGBM, which
  handles NaN natively. Dropping rows biases the training set.

## 3. Build Order

The panel is built in five stages. Each stage is a separate function and
can be tested in isolation.

    1. Load prices and fundamentals
    2. Compute raw features (per ticker, time-series)
    3. Compute cross-sectional ranks (per date, across tickers)
    4. Compute forward returns (targets)
    5. Assign train/cal/test splits

Do not interleave these stages. A function that both computes a feature
and assigns a split is a bug waiting to happen.

## 4. Raw Features

See `FEATURES.md` for exact formulas. The six:

- `mom_20d` — 20-trading-day return
- `mom_60d` — 60-trading-day return
- `mom_12m_1m` — 12-month return skipping the most recent month
- `vol_60d_res` — 60-day residual volatility (idiosyncratic)
- `sp_ratio` — sales-to-price (trailing twelve months revenue / market cap)
- `turn_20d` — 20-day mean turnover (volume / shares outstanding)

Every feature is computed per ticker in time order. No feature looks
across tickers. No feature looks forward.

## 5. Cross-Sectional Ranks

See `CROSS-SECTIONAL.md`. The six raw features each produce a rank
column. Ranks are computed per date:

    r_mom_20d[i, t] = percentile_rank(mom_20d[:, t], mom_20d[i, t])

Ranks are in [0, 1] via `(rank - 1) / (N - 1)` where N is the number of
eligible tickers on date `t`. Ties are broken by average rank.

**Universe requirement:** at least 50 eligible tickers on date `t`. If
fewer, ranks are set to NaN for that date. The linter does not enforce
this; the code must.

## 6. Targets

See `TARGETS.md`. Three forward excess returns:

- `y_fwd_63d` = 63-trading-day forward return minus risk-free return over
  the same period
- `y_fwd_126d` = 126-trading-day forward excess return
- `y_fwd_252d` = 252-trading-day forward excess return

A target is NaN if the forward window extends beyond the last available
price date for that ticker. This is the correct behavior — do not
impute, do not drop the row.

## 7. Train / Cal / Test Split

The split column is assigned chronologically per ticker:

| Split | Rule |
|---|---|
| `train` | Date is in the earliest 60% of the available history |
| `cal` | Date is in the next 20% |
| `test` | Date is in the final 20% |

The split is assigned at the ticker level. A ticker's earliest 60% of
trading days are `train`, regardless of what other tickers are doing.
This ensures each ticker contributes to every phase.

**The forecast origin boundary** (used by TCP, see `04-tcp-calibration`)
is separate from the split column. TCP rolls its own windows; the split
column is for model training and backtest evaluation only.

## 8. What Not to Do

- Do not compute features using future prices. Use `shift(N)` (backward),
  never `shift(-N)` (forward).
- Do not forward-fill targets. NaN means "unknown," not "carry forward."
- Do not drop rows with NaN features. LightGBM handles them.
- Do not compute cross-sectional ranks with fewer than 50 names.
- Do not use expanding windows for Z-score normalization. Use rolling
  60-day windows. See `FEATURES.md` §3.
- Do not use `period_end` for any fundamental join. Use `filing_date`.
- Do not reorder columns. The order in `SCHEMAS.md` §5 is frozen.
- Do not overwrite `panel.parquet` in place. Write temp, atomic rename.
- Do not include tickers that are not in the eligible universe on the
  date being processed.

## 9. Verification

Before committing any panel change:

- [ ] A test recomputes a known feature value from a known price series
- [ ] A test asserts no feature uses future data (shuffle test)
- [ ] A test asserts rank features are NaN when universe < 50
- [ ] A test asserts targets are NaN beyond the horizon
- [ ] A test asserts the split assignment matches the 60/20/20 rule
- [ ] `scripts/validate-panel.jl` passes
- [ ] The panel's schema hash matches the registry
- [ ] Re-running on the same input produces byte-identical output

## 10. Related Skills

- `00-constitution` §2, §3 — point-in-time and no-lookahead
- `01-data-ingestion` — produces the inputs
- `03-gspqr-model` — consumes the panel
- `13-parquet-lake` — schema definition
- `14-backtest-protocol` — uses split column for evaluation