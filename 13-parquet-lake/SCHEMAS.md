
---

## `SCHEMAS.md`

```markdown
# Schema Definitions

Every column, every type, every writer. This file is normative. If code
disagrees with this file, the code is wrong.

Types use Arrow notation. `date32` = days since epoch. `timestamp[ns, UTC]`
= nanosecond precision, UTC timezone. `utf8` = string. `bool` = boolean.

---

## 1. `universe.parquet`

Rows: ~650. Writer: Julia (universe builder). Update: monthly.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | Primary key with `effective_date` |
| `etf_source` | `utf8` | no | One of `IWF`, `IWP`, `IJT` |
| `effective_date` | `date32` | no | Date added to universe |
| `end_date` | `date32` | yes | Null if currently eligible |
| `eligible` | `bool` | no | Current eligibility flag |
| `exclusion_reason` | `utf8` | yes | `liquidity` / `data_quality` / `delisted` / null |
| `median_dollar_vol_60d` | `float64` | no | Trailing 60-day median, USD |
| `data_years` | `float32` | no | Years of clean history available |

Partitioned: no.

---

## 2. `prices.parquet`

Rows: ~800K. Writer: Rust (ingest). Update: daily. Partitioned: `year/month`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `date` | `date32` | no | NYSE trading day |
| `open` | `float64` | no | Adjusted |
| `high` | `float64` | no | Adjusted |
| `low` | `float64` | no | Adjusted |
| `close` | `float64` | no | Adjusted |
| `volume` | `int64` | no | Shares |
| `adj_close` | `float64` | no | Split/dividend adjusted close |

Primary key: `(ticker, date)`.

---

## 3. `fundamentals.parquet`

Rows: ~13K. Writer: Rust (ingest). Update: on filing. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `filing_date` | `date32` | no | **Point-in-time stamp** |
| `period_end` | `date32` | no | Metadata only, never a decision variable |
| `form_type` | `utf8` | no | `10-Q` / `10-K` / `8-K` |
| `revenues` | `float64` | yes | USD |
| `net_income` | `float64` | yes | USD |
| `total_assets` | `float64` | yes | USD |
| `total_liabilities` | `float64` | yes | USD |
| `operating_cash_flow` | `float64` | yes | USD |
| `gross_profit` | `float64` | yes | USD |
| `assets_current` | `float64` | yes | USD |
| `liabilities_current` | `float64` | yes | USD |
| `long_term_debt` | `float64` | yes | USD |
| `retained_earnings` | `float64` | yes | USD |
| `ebit` | `float64` | yes | USD |
| `shares_outstanding` | `float64` | yes | Count |

Primary key: `(ticker, filing_date, form_type)`.

---

## 4. `macro.parquet`

Rows: ~1.3K. Writer: Rust (ingest). Update: daily. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `date` | `date32` | no | |
| `treasury_3m` | `float64` | yes | Percent |
| `treasury_2y` | `float64` | yes | Percent |
| `treasury_10y` | `float64` | yes | Percent |
| `yield_curve_slope` | `float64` | yes | `10y - 2y` |
| `hy_credit_spread` | `float64` | yes | OAS, percent |
| `ig_credit_spread` | `float64` | yes | OAS, percent |
| `cpi` | `float64` | yes | Indexed |
| `fed_funds_rate` | `float64` | yes | Percent |
| `unemployment_rate` | `float64` | yes | Percent |
| `vix` | `float64` | yes | Index |

Primary key: `date`.

---

## 5. `panel.parquet`

Rows: ~800K. Writer: Julia (feature engine). Update: daily. Partitioned: `year/month`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `date` | `date32` | no | |
| `split` | `utf8` | no | `train` / `cal` / `test` |
| `y_fwd_63d` | `float64` | yes | NaN beyond horizon |
| `y_fwd_126d` | `float64` | yes | NaN beyond horizon |
| `y_fwd_252d` | `float64` | yes | NaN beyond horizon |
| `mom_20d` | `float64` | yes | |
| `mom_60d` | `float64` | yes | |
| `mom_12m_1m` | `float64` | yes | |
| `vol_60d_res` | `float64` | yes | |
| `sp_ratio` | `float64` | yes | |
| `turn_20d` | `float64` | yes | |
| `r_mom_20d` | `float64` | yes | Cross-sectional rank |
| `r_mom_60d` | `float64` | yes | |
| `r_mom_12m_1m` | `float64` | yes | |
| `r_vol_60d` | `float64` | yes | |
| `r_sp` | `float64` | yes | |
| `r_turn` | `float64` | yes | |

Primary key: `(ticker, date)`. Feature column order is frozen.

---

## 6. `regime_states.parquet`

Rows: ~1.3K. Writer: Julia (regime). Update: daily. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `date` | `date32` | no | |
| `regime_low_vol_prob` | `float64` | no | Sums to 1.0 with others |
| `regime_high_vol_prob` | `float64` | no | |
| `regime_crisis_prob` | `float64` | no | |
| `viterbi_state` | `utf8` | no | `low_vol` / `high_vol` / `crisis` |
| `regime_factor` | `float64` | no | 1.0 / 0.5 / 0.0 |

Primary key: `date`.

---

## 7. `gspqr_predictions.parquet`

Rows: ~500K. Writer: Julia (GSPQR). Update: daily. Partitioned: `year/month`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `date` | `date32` | no | Forecast origin |
| `horizon` | `utf8` | no | `63d` / `126d` / `252d` |
| `q_01` | `float64` | no | |
| `q_05` | `float64` | no | |
| `q_25` | `float64` | no | |
| `q_50` | `float64` | no | Median, used by optimizer |
| `q_75` | `float64` | no | |
| `q_95` | `float64` | no | |
| `q_99` | `float64` | no | |

Primary key: `(ticker, date, horizon)`.

---

## 8. `tcp_calibration.parquet`

Rows: ~500K. Writer: Julia (TCP). Update: daily. Partitioned: `year/month`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `forecast_date` | `date32` | no | |
| `horizon` | `utf8` | no | |
| `alpha` | `float64` | no | 0.05 nominal |
| `m_cal` | `int32` | no | Calibration window size, 60 |
| `k_order_stat` | `int32` | no | `ceil((m+1)(1-alpha))` |
| `q_hat_lower` | `float64` | no | Calibrated 5% bound |
| `q_hat_upper` | `float64` | no | Calibrated 95% bound |
| `rm_offset` | `float64` | no | Robbins-Monro offset |
| `calib_width` | `float64` | no | `q_hat_upper - q_hat_lower` |

Primary key: `(ticker, forecast_date, horizon)`.

---

## 9. `evt_residuals.parquet`

Rows: ~500K. Writer: Julia (EVT). Update: daily. Partitioned: `year/month`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `date` | `date32` | no | |
| `horizon` | `utf8` | no | |
| `realized_return` | `float64` | no | Forward return |
| `calibrated_mid` | `float64` | no | TCP interval midpoint |
| `residual` | `float64` | no | `realized - mid` |
| `exceed_lower` | `bool` | no | `residual < u_lower` |
| `exceed_upper` | `bool` | no | `residual > u_upper` |

Primary key: `(ticker, date, horizon)`.

---

## 10. `evt_tail_bounds.parquet`

Rows: ~1.5K. Writer: Julia (EVT). Update: daily. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `fit_date` | `date32` | no | |
| `horizon` | `utf8` | no | |
| `tail` | `utf8` | no | `lower` / `upper` |
| `threshold_u` | `float64` | no | |
| `n_exceedances` | `int32` | no | Must be ≥ 50 |
| `gpd_shape_xi` | `float64` | no | |
| `gpd_scale_sigma` | `float64` | no | |
| `q_extreme` | `float64` | no | 1% or 99% bound |

Primary key: `(ticker, fit_date, horizon, tail)`.

---

## 11. `conviction_scores.parquet`

Rows: ~150K. Writer: Julia (conviction). Update: filing + daily. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `as_of_date` | `date32` | no | |
| `filing_date` | `date32` | no | Most recent filing used |
| `f_score_z` | `float64` | yes | Cross-sectional z |
| `roic_spread_z` | `float64` | yes | |
| `accruals_z` | `float64` | yes | Sign-flipped |
| `gm_trend_z` | `float64` | yes | |
| `rev_persist_z` | `float64` | yes | |
| `revision_z` | `float64` | yes | |
| `composite_z` | `float64` | yes | Weighted sum |
| `conviction` | `float64` | no | `clip(1.0 + 0.12*z, 0.50, 1.25)` |
| `components_used` | `int32` | no | Non-missing components |

Primary key: `(ticker, as_of_date)`.

---

## 12. `veto_flags.parquet`

Rows: ~650. Writer: Julia (conviction). Update: filing + daily. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | |
| `as_of_date` | `date32` | no | |
| `filing_date` | `date32` | yes | Null if no filing yet |
| `altman_z` | `float64` | yes | |
| `going_concern` | `bool` | no | |
| `neg_book_neg_ocf` | `bool` | no | Both conditions |
| `delisting_notice` | `bool` | no | |
| `restatement_12m` | `bool` | no | |
| `auditor_resigned` | `bool` | no | |
| `covenant_breach` | `bool` | no | |
| `veto_active` | `bool` | no | OR of all triggers + `altman_z < 1.8` |

Primary key: `(ticker, as_of_date)`.

---

## 13. `portfolio_targets.parquet`

Rows: ~650 per rebalance. Writer: Julia (portfolio). Update: event-driven. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `rebalance_date` | `date32` | no | |
| `ticker` | `utf8` | no | |
| `expected_return` | `float64` | no | GSPQR 50th percentile |
| `downside_risk` | `float64` | no | Lower semi-deviation |
| `w_optimized` | `float64` | no | Pre-conviction |
| `conviction` | `float64` | no | From `conviction_scores` |
| `w_conviction` | `float64` | no | `w_optimized * conviction` |
| `w_final` | `float64` | no | Renormalized, capped |
| `veto_active` | `bool` | no | |
| `cap_applied` | `bool` | no | 5% single-name hit |

Primary key: `(rebalance_date, ticker)`.

---

## 14. `position_locks.parquet`

Rows: ~650. Writer: Rust (lock monitor). Update: event-driven. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | Primary key |
| `state` | `utf8` | no | One of four states |
| `last_buy_date` | `date32` | yes | |
| `last_sell_date` | `date32` | yes | |
| `lock_expiry_date` | `date32` | yes | Trading days, not calendar |
| `shares_held` | `int64` | no | |
| `pending_side` | `utf8` | yes | `Buy` / `Sell` / null |

Primary key: `ticker`.

---

## 15. `pending_orders.parquet`

Rows: ~50. Writer: Rust (order manager). Update: event-driven. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `pending_id` | `utf8` | no | UUID |
| `ticker` | `utf8` | no | |
| `side` | `utf8` | no | `Buy` / `Sell` |
| `target_quantity` | `int64` | no | |
| `earliest_execution` | `date32` | no | Lock expiry |
| `signal_snapshot` | `utf8` | no | JSON |
| `created_at` | `timestamp[ns, UTC]` | no | |
| `status` | `utf8` | no | `Pending` / `Fired` / `Cancelled` / `Expired` |
| `cancelled_reason` | `utf8` | yes | `signal_reversed` / `lock_extended` / null |

Primary key: `pending_id`.

---

## 16. `orders.parquet`

Rows: ~5K/year. Writer: Rust (execution). Update: event-driven. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `order_id` | `utf8` | no | UUID |
| `schwab_order_id` | `utf8` | yes | Null until accepted |
| `ticker` | `utf8` | no | |
| `side` | `utf8` | no | `Buy` / `Sell` |
| `quantity` | `int64` | no | |
| `order_type` | `utf8` | no | `Limit` / `Stop` / `StopLimit` / `OCO` / `Bracket` / `MOC` / `LOC` |
| `limit_price` | `float64` | yes | Required for Limit |
| `status` | `utf8` | no | `Pending` / `Filled` / `Partial` / `Cancelled` / `Rejected` |
| `submitted_at` | `timestamp[ns, UTC]` | no | |
| `filled_at` | `timestamp[ns, UTC]` | yes | |
| `fill_price` | `float64` | yes | VWAP across fills |
| `fill_quantity` | `int64` | no | Cumulative |
| `slippage_bps` | `float64` | yes | vs mid at submission |

Primary key: `order_id`.

---

## 17. `positions.parquet`

Rows: ~650. Writer: Rust (execution). Update: daily. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `ticker` | `utf8` | no | Primary key |
| `shares` | `int64` | no | |
| `avg_cost` | `float64` | no | |
| `current_price` | `float64` | no | |
| `market_value` | `float64` | no | |
| `unrealized_pnl` | `float64` | no | |
| `weight` | `float64` | no | `market_value / portfolio_value` |
| `entry_date` | `date32` | yes | Null if `shares == 0` |
| `holding_days` | `int32` | no | Trading days since entry |

Primary key: `ticker`.

---

## 18. `fills.parquet`

Rows: ~8K/year. Writer: Rust (execution). Update: event-driven. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `fill_id` | `utf8` | no | UUID |
| `order_id` | `utf8` | no | FK to `orders` |
| `ticker` | `utf8` | no | |
| `side` | `utf8` | no | |
| `quantity` | `int64` | no | |
| `price` | `float64` | no | |
| `filled_at` | `timestamp[ns, UTC]` | no | |
| `venue` | `utf8` | yes | Exchange |
| `commission` | `float64` | no | |

Primary key: `fill_id`.

---

## 19. `evaluation_metrics.parquet`

Rows: ~250/year. Writer: Julia (backtest). Update: daily. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `eval_date` | `date32` | no | |
| `horizon` | `utf8` | no | |
| `coverage_95` | `float64` | no | Empirical |
| `coverage_90` | `float64` | no | |
| `avg_width` | `float64` | no | Mean interval width |
| `winkler_score` | `float64` | no | Lower is better |
| `pinball_loss` | `float64` | no | Averaged over τ |
| `crps` | `float64` | no | |
| `rank_ic` | `float64` | no | Spearman, cross-sectional |
| `n_obs` | `int32` | no | Universe size |

Primary key: `(eval_date, horizon)`.

---

## 20. `data_quality.parquet`

Rows: ~2K/year. Writer: Rust (ingest). Update: daily. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `date` | `date32` | no | |
| `source` | `utf8` | no | `Yahoo` / `SEC` / `FRED` / `Schwab` / `iShares` |
| `dataset` | `utf8` | no | |
| `tickers_expected` | `int32` | no | |
| `tickers_received` | `int32` | no | |
| `missing_pct` | `float64` | no | |
| `latency_min` | `int32` | no | From scheduled time |
| `status` | `utf8` | no | `OK` / `WARN` / `FAIL` |
| `notes` | `utf8` | yes | |

Primary key: `(date, source, dataset)`.

---

## 21. `audit_log.parquet`

Rows: ~20K/year. Writer: Rust (event bus). Update: event-driven. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `event_id` | `utf8` | no | UUID |
| `timestamp` | `timestamp[ns, UTC]` | no | |
| `event_type` | `utf8` | no | See enum below |
| `ticker` | `utf8` | yes | Null for non-ticker events |
| `actor` | `utf8` | no | `system` / `schwab` / `manual` |
| `details` | `utf8` | no | JSON |
| `severity` | `utf8` | no | `INFO` / `WARN` / `CRITICAL` |

Append-only. No primary key. Ordering by `timestamp`.

Event types: `order_submitted`, `order_filled`, `order_cancelled`,
`lock_transition`, `lock_violation_blocked`, `veto_triggered`,
`regime_flip`, `position_reconciled`, `manual_override`,
`kill_switch_activated`.

## 22. `portfolio_ledger.parquet`

Rows: ~252/year. Writer: Julia (ledger). Update: daily. Partitioned: `year`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `date` | `date32` | no | Primary key |
| `cash` | `float64` | no | USD |
| `cash_pct` | `float64` | no | |
| `market_value` | `float64` | no | |
| `total_value` | `float64` | no | `cash + market_value` |
| `cost_basis` | `float64` | no | |
| `unrealized_pnl` | `float64` | no | |
| `realized_pnl_today` | `float64` | no | |
| `realized_pnl_ytd` | `float64` | no | |
| `n_positions` | `int32` | no | |
| `daily_return` | `float64` | no | vs prior day |
| `cumulative_return` | `float64` | no | since inception |
| `max_drawdown` | `float64` | no | trailing 252d |
| `sortino_252d` | `float64` | no | trailing 252d |
| `regime_factor` | `float64` | no | |
| `reconciled` | `bool` | no | |
| `backfilled` | `bool` | no | false for live rows |

Primary key: `date`.

## 23. `tax_lots.parquet`

Rows: ~1000s total. Writer: Rust (execution). Update: event-driven. Partitioned: no.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `lot_id` | `utf8` | no | Primary key |
| `ticker` | `utf8` | no | |
| `open_date` | `date32` | no | |
| `open_price` | `float64` | no | |
| `open_quantity` | `int64` | no | Reduced on partial close |
| `close_date` | `date32` | yes | Null if open |
| `close_price` | `float64` | yes | |
| `close_quantity` | `int64` | no | 0 if open |
| `realized_pnl` | `float64` | yes | Null if open |
| `holding_days` | `int32` | no | Calendar days |
| `order_id_open` | `utf8` | no | FK to orders |
| `order_id_close` | `utf8` | yes | FK to orders |

Primary key: `lot_id`.

## 24. `trade_summary.parquet`

Rows: ~500/year. Writer: Julia (ledger). Update: event-driven (on close). Partitioned: `year`.

| Column | Type | Nullable | Notes |
|---|---|---|---|
| `trade_id` | `utf8` | no | Primary key |
| `ticker` | `utf8` | no | |
| `entry_date` | `date32` | no | Earliest open date |
| `exit_date` | `date32` | no | Latest close date |
| `entry_price` | `float64` | no | Weighted-average |
| `exit_price` | `float64` | no | Weighted-average |
| `quantity` | `float64` | no | Fractional permitted |
| `gross_return_bps` | `float64` | no | |
| `slippage_bps` | `float64` | no | Quantity-weighted |
| `net_return_bps` | `float64` | no | |
| `benchmark_return_bps` | `float64` | no | Equal-weighted universe |
| `alpha_bps` | `float64` | no | |
| `holding_days` | `int32` | no | Trading days |
| `return_per_day_bps` | `float64` | no | |
| `downside_deviation_bps` | `float64` | yes | Null if no down days |
| `trade_sortino` | `float64` | yes | Null if downside deviation is 0 |
| `regime_at_entry` | `utf8` | no | |
| `regime_at_exit` | `utf8` | no | |
| `conviction_at_entry` | `float64` | no | |
| `tier_at_entry` | `utf8` | no | |
| `lock_overridden` | `bool` | no | True on veto-forced exit |

Primary key: `trade_id`.