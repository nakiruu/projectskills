# Quant Trading System: Functional Outline

A single-stock and small-universe quant trading system. It produces probabilistic price ranges for 3–12 month horizons, builds a portfolio, places orders through the Schwab API, enforces a 5-day transaction lock, and keeps a daily ledger. It runs on an Unraid server inside Docker containers. The languages are Julia (analytics), Rust (execution), and Bun/TypeScript (frontend).

## Universe

Two iShares ETFs are the starting universe: IWF (large-cap growth) and IWP (mid-cap growth). IJT (small-cap growth) is a potential expansion. The universe is refreshed monthly from iShares holdings files. Names below $5M median daily dollar volume or with fewer than 3 years of clean data are excluded.

## Data

Four sources are used:

- **Yahoo Finance** for daily prices, valuation snapshots, and earnings dates. No API key.
- **SEC EDGAR** for quarterly financial statements. Point-in-time stamped with filing dates. No API key, but requires a User-Agent email header.
- **FRED** for macro series (treasury yields, credit spreads, CPI, VIX). Free API key.
- **iShares** for ETF holdings CSVs. No API key.

Every data point is timestamped with its publication date, not its observation date. SEC filings use `filing_date`, never `period_end`. This is the system's most important rule and is enforced by a linter and a validation script.

## Prediction Engine

Three layers:

1. **GSPQR** — 21 LightGBM models (3 horizons × 7 quantiles) trained on 12 features. Six raw features (momentum at 20/60 days and 12-month-minus-1-month, residual volatility, sales-to-price, turnover) and six cross-sectional ranks of those features. Trained monthly in Julia.
2. **TCP** — Rolling split-conformal calibration. Uses the most recent 60 trading days as a calibration window. Produces calibrated 5% and 95% bounds. Applies a Robbins-Monro offset to steer coverage toward the nominal 95% in real time.
3. **EVT** — Peaks-over-threshold with a Generalized Pareto Distribution. Extends the calibrated 5%/95% interval to 1%/99% using exceedances above the 95th percentile of calibrated residuals.

Output per stock per horizon: 7 raw quantiles, 2 calibrated bounds, 2 extreme bounds.

## Regime Gate

A 3-state Gaussian Hidden Markov Model on daily equal-weighted universe returns. States are labeled low-volatility, high-volatility, and crisis by emission variance. Position sizing multiplier: 1.0, 0.5, or 0.0. Requires 2 consecutive days in a new state before acting.

## Fundamental Overlay

Two distinct jobs:

- **Veto** (binary, before optimizer): seven triggers — Altman Z below 1.8, going-concern qualification, negative book plus negative operating cash flow, pending delisting, material restatement, auditor resignation, or covenant breach. A vetoed stock is removed from the universe entirely.
- **Conviction** (bounded scalar, after optimizer): six quality components — Piotroski F-Score, ROIC minus WACC spread, accruals ratio, gross margin trend, revenue growth persistence, analyst revision breadth. Cross-sectionally standardized via median/MAD. Mapped to a multiplier in [0.50, 1.25] via `1.0 + 0.12 * z`.

Valuation is excluded from conviction because it is already a GSPQR feature.

## Portfolio Optimization

Post-Modern Portfolio Theory. Maximizes the Sortino ratio (return over downside deviation) instead of the Sharpe ratio. Formulated as a Second-Order Cone Program and solved with Clarabel via `PortfolioOptimisers.jl`. Constraints: 5% maximum per name, 25% maximum per GICS sector, 2% minimum cash, long-only.

Conviction is applied after optimization, then weights are renormalized and caps are redistributed iteratively.

The optimizer produces weights, not share quantities. The conversion to quantities happens in the Rust order generator, which knows the execution tier.

## Execution Tiers

The order type is determined by the trailing 5-day mean NAV at submission time. Three tiers:

| Tier | Trailing 5-day mean NAV | Order policy |
|---|---|---|
| **Bootstrap** | < $2,500 | Fractional market orders only. Limit orders are not submitted. |
| **Transition** | $2,500 – $10,000 | Limit orders are the default. Market orders permitted only for fractional share quantities that cannot be expressed as whole-share limits. |
| **Standard** | > $10,000 | Limit orders only. Market orders are not submitted. |

The Bootstrap tier exists because Schwab rounds limit orders up to whole shares and enforces minimums that a sub-$1,000 account cannot meet. Fractional shares require market orders; Schwab does not support fractional limits.

The tier is checked at order submission time, not cached. A NAV crossing a tier boundary takes effect on the next order. The 5-day lock applies in all tiers.

In the Transition tier, the order generator produces a whole-share limit for the integer portion and a fractional market for the remainder. In the Standard tier, quantities are rounded to whole shares and the residual returns to cash.

The Rust `OrderType` enum contains both `Limit` and `Market` variants. The `Market` variant is only constructible inside the Bootstrap tier or the Transition tier's fractional path. A compile-time check prevents market orders outside those tiers.

## The 5-Day Lock

A position cannot reverse direction within 5 trading days of the last same-direction action. Adding to a position in the same direction is always allowed and resets the timer. Reversing is forbidden. The lock is enforced at three layers:

1. **Compile-time** in Rust: lock states are types, not enums. `sell()` does not exist on `LongLocked`, so a violating call does not compile.
2. **Runtime pre-submit check**: the execution engine queries `position_locks.parquet` and the broker's position before every order.
3. **Daily reconciliation**: local positions are compared against Schwab's reported positions after close. Mismatch halts trading.

Orders blocked by the lock are written to `pending_orders.parquet`. On lock expiry, a Rust timer fires, re-validates the signal against the queued snapshot, and either submits or cancels.

## Execution Engine

Rust only.

- **Schwab API** for order submission, account data, and WebSocket quotes.
- **OAuth 2.0**: access token ~30 minutes, refresh token ~7 days.
- **No paper environment**: Schwab has none. A shadow engine simulates fills alongside real submissions and flags divergence. The shadow engine uses a tier-specific slippage model: limit orders cross a partial spread (~5 bps), market orders cross the full spread (fill at ask for buys, bid for sells).
- **Order types supported**: Limit, StopLimit, TrailingStop, OCO, Bracket, LOC. Plain Stop is forbidden above Bootstrap because it produces a market order. OCO, bracket, trailing stop, and stop-limit are not used in the Bootstrap tier because they require whole shares.

Pre-trade checks in Rust: position cap, sector cap, cash buffer, lock state, execution tier. All must pass before an order reaches Schwab.

## Event Bus

Tokio. Six typed bounded channels: `market_data`, `order_events`, `lock_events`, `regime`, `filing`, `audit`. Every handler checks a deduplication set (UUID) before processing. The audit channel is load-bearing: if it fills, trading halts. All state changes write an audit row before returning.

`OrderSubmitted` and `OrderFilled` events carry a `tier` field and use `Decimal` for quantity to support fractional orders.

## Ledger

Two files:

- **`portfolio_ledger.parquet`** — one row per trading day, written after reconciliation. Contains cash, market value, cost basis, unrealized P&L, realized P&L (today and year-to-date), number of positions, daily return, cumulative return, trailing drawdown, trailing Sortino, regime factor, and reconciliation status. All quantities are `float64`.
- **`tax_lots.parquet`** — one row per purchase, updated on sale via FIFO matching. Partial closes split the lot into two rows: one for the closed portion, one for the remainder. Full closes update the row in place.

Realized P&L is `(close_price − open_price) × close_quantity`. Holding period is calendar days (for short-term vs long-term classification). The ledger is the source of truth for tax reporting, drawdown calculation, and broker reconciliation.

In the Bootstrap and Transition tiers, `daily_return` reflects the spread cost of market orders. A bootstrap-tier account's returns are systematically lower than a standard-tier account's returns by the average spread per trade. The backtest models the same cost structure, so live and simulated results are comparable.

## Language Boundaries

| Layer | Language |
|---|---|
| Analytics, model training, calibration, portfolio, regime, conviction, ledger, backtest | Julia |
| Execution, data ingestion, event bus, risk, lot tracking | Rust |
| Dashboard, API, visualization | Bun/TypeScript |
| Data storage | Parquet + DuckDB |
| Julia ↔ Rust bridge | RustCall.jl, jlrs, Arrow IPC |

The execution hot path does not cross the Julia boundary. Rust calls Julia only for batch model inference, once per day.

## Data Lake

23 Parquet files, ZSTD-compressed, schema-immutable. Large daily files are partitioned by year/month. Single-writer rule: each file has exactly one writing module. Schemas are hashed in `schemas/registry.json` and verified by CI. Additive changes only.

## Backtest

Combinatorial Purged Cross-Validation (CPCV) with 21-day purge and 21-day embargo. Ten groups, eight test groups per fold, 36 backtest paths. Metrics are reported as distributions across paths, not point estimates: coverage, Winkler score, pinball loss, CRPS, Sortino, max drawdown, Sharpe. The Deflated Sharpe Ratio is reported only when the number of tuning trials is logged.

The execution simulator is tier-aware. It reads the tier from the simulated NAV at each step and applies the corresponding fill model: market orders fill at ask (buy) or bid (sell), limit orders fill at mid. The simulator's limit-order fills are optimistic and overstate the Sharpe ratio slightly in the Standard tier. This is documented as a known limitation.

Two starting-NAV configurations are reported: $1,000 (Bootstrap-realistic) and $100,000 (Standard-research).

## Deployment

Unraid host. Two containers:

- **`quant-core`**: Julia and Rust co-located. The only writer of the Parquet lake. Mounts the XFS cache pool at `/mnt/cache/quant/` read-write.
- **`quant-api`**: Bun. Reads Parquet read-only. Serves the dashboard.

All live data lives on the XFS cache pool. The array is a nightly rsync backup with checksum verification. XFS provides no snapshots and no block checksums, so the mitigation is a monthly full read-through validation job. Containers run as UID 99 / GID 100. Docker network type is ipvlan.

Daily schedule: prices at 16:10 ET, reconciliation at 16:15, tax lots at 16:20, ledger at 16:25, model inference at 16:30, portfolio optimization at 17:00, pending orders at 17:30, backup at 18:00.

## Governance

The system is defined by 17 `.claude/skills/` documents. Each skill covers one layer, with parameters, procedures, anti-patterns, and verification checklists. A constitution at `00-constitution` defines the invariants that no code may violate. Three amendments have been made:

1. **Amendment 1.1** — permits in-place update of `tax_lots.parquet` on full close and reduction of `open_quantity` on partial close.
2. **Amendment 1.2** — replaces "limit orders only" with the three-tier NAV execution model.

A pre-commit hook catches some invariants mechanically; the rest require review. An append-only amendment log records every constitutional change.

## What the System Does Not Do

- No shorting, no options, no futures.
- No intraday rebalancing. The lock makes it impossible and the horizon makes it unnecessary.
- No directional regime prediction. The HMM identifies volatility states, not bull or bear markets.
- No high-frequency execution. The signal half-life is weeks; the execution latency budget is seconds.
- No news sentiment, no LLM decisions, no discretionary overrides except the documented veto exception.
- No market orders above $2,500 NAV except for fractional remainders in the Transition tier.