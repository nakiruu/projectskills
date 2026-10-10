# Codebase Scaffold (Updated)

The complete directory layout, now including the ledger layer. Every file the skills reference has a home.

```
quant/
├── .claude/
│   └── skills/                          # All 17 skills
│       ├── 00-constitution/
│       ├── 01-data-ingestion/
│       ├── 02-panel-construction/
│       ├── 03-gspqr-model/
│       ├── 04-tcp-calibration/
│       ├── 05-evt-tails/
│       ├── 06-regime-detection/
│       ├── 07-fundamental-overlay/
│       ├── 08-portfolio-optimization/
│       ├── 09-lock-state-machine/
│       ├── 10-execution-schwab/
│       ├── 11-rust-event-bus/
│       ├── 12-julia-rust-bridge/
│       ├── 13-parquet-lake/
│       ├── 14-backtest-protocol/
│       ├── 15-ai-dev-workflow/
│       └── 16-portfolio-ledger/
│
├── models/                              # Julia: GSPQR training & inference
│   ├── Project.toml
│   ├── Manifest.toml
│   ├── src/
│   │   ├── QuantModels.jl
│   │   ├── gspqr/
│   │   │   ├── train.jl
│   │   │   ├── features.jl
│   │   │   ├── params.jl
│   │   │   └── export.jl
│   │   ├── tcp/
│   │   │   ├── calibrate.jl
│   │   │   ├── scores.jl
│   │   │   └── robbins_monro.jl
│   │   ├── evt/
│   │   │   ├── fit.jl
│   │   │   ├── threshold.jl
│   │   │   └── extrapolate.jl
│   │   └── inference/
│   │       └── predict.jl
│   └── test/
│       ├── runtests.jl
│       ├── test_gspqr.jl
│       ├── test_tcp.jl
│       └── test_evt.jl
│
├── features/                            # Julia: panel construction
│   ├── Project.toml
│   ├── src/
│   │   ├── Features.jl
│   │   ├── raw.jl
│   │   ├── ranks.jl
│   │   ├── targets.jl
│   │   ├── splits.jl
│   │   └── panel.jl
│   └── test/
│       ├── runtests.jl
│       ├── test_raw.jl
│       ├── test_ranks.jl
│       └── test_targets.jl
│
├── portfolio/                           # Julia: optimization
│   ├── Project.toml
│   ├── src/
│   │   ├── Portfolio.jl
│   │   ├── pmpt.jl
│   │   ├── covariance.jl
│   │   ├── constraints.jl
│   │   └── conviction_apply.jl
│   └── test/
│       └── runtests.jl
│
├── regime/                              # Julia: HMM
│   ├── Project.toml
│   ├── src/
│   │   ├── Regime.jl
│   │   ├── fit.jl
│   │   ├── decode.jl
│   │   ├── relabel.jl
│   │   └── confirm.jl
│   └── test/
│       └── runtests.jl
│
├── conviction/                          # Julia: fundamental overlay
│   ├── Project.toml
│   ├── src/
│   │   ├── Conviction.jl
│   │   ├── veto.jl
│   │   ├── f_score.jl
│   │   ├── altman_z.jl
│   │   ├── components.jl
│   │   └── standardize.jl
│   └── test/
│       └── runtests.jl
│
├── ledger/                              # Julia: portfolio ledger & tax lots
│   ├── Project.toml
│   ├── src/
│   │   ├── Ledger.jl
│   │   ├── daily.jl                     # write-ledger-row
│   │   ├── metrics.jl                   # drawdown, Sortino, cumulative
│   │   ├── realized.jl                  # YTD realized P&L
│   │   └── query.jl                     # common ledger queries
│   └── test/
│       ├── runtests.jl
│       ├── test_daily.jl
│       └── test_realized.jl
│
├── backtest/                            # Julia: CPCV evaluation
│   ├── Project.toml
│   ├── src/
│   │   ├── Backtest.jl
│   │   ├── cpcv.jl
│   │   ├── metrics.jl
│   │   └── paths.jl
│   └── test/
│       └── runtests.jl
│
├── execution/                           # Rust: production hot path
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── src/
│   │   ├── main.rs
│   │   ├── lib.rs
│   │   ├── locks/
│   │   │   ├── mod.rs
│   │   │   ├── state.rs                 # Typestate
│   │   │   ├── transitions.rs
│   │   │   ├── pending.rs
│   │   │   └── monitor.rs
│   │   ├── schwab/
│   │   │   ├── mod.rs
│   │   │   ├── oauth.rs
│   │   │   ├── orders.rs
│   │   │   ├── client.rs
│   │   │   └── shadow.rs
│   │   ├── eventbus/
│   │   │   ├── mod.rs
│   │   │   ├── channels.rs
│   │   │   ├── events.rs
│   │   │   ├── dedup.rs
│   │   │   └── handlers.rs
│   │   ├── audit/
│   │   │   ├── mod.rs
│   │   │   ├── writer.rs
│   │   │   └── types.rs
│   │   ├── risk/
│   │   │   ├── mod.rs
│   │   │   ├── pre_trade.rs
│   │   │   └── reconciliation.rs
│   │   ├── lots/                        # NEW: tax lot tracking
│   │   │   ├── mod.rs
│   │   │   ├── updater.rs               # FIFO matching
│   │   │   ├── types.rs                 # TaxLot struct
│   │   │   └── split.rs                 # partial-close logic
│   │   ├── inference/
│   │   │   ├── mod.rs
│   │   │   └── bosk_loader.rs
│   │   └── data/
│   │       ├── mod.rs
│   │       ├── parquet.rs
│   │       └── arrow_ipc.rs
│   ├── tests/
│   │   ├── lock_state_machine.rs
│   │   ├── execution_guards.rs
│   │   ├── event_bus.rs
│   │   ├── export_roundtrip.rs
│   │   ├── lot_fifo.rs                  # NEW: FIFO correctness
│   │   └── lot_partial_close.rs         # NEW: split correctness
│   └── benches/
│       └── order_submit.rs
│
├── ingest/                              # Rust: data fetching
│   ├── Cargo.toml
│   ├── src/
│   │   ├── main.rs
│   │   ├── lib.rs
│   │   ├── yahoo.rs
│   │   ├── edgar.rs
│   │   ├── fred.rs
│   │   ├── ishares.rs
│   │   ├── rate_limit.rs
│   │   ├── retry.rs
│   │   ├── atomic_write.rs
│   │   └── quality_log.rs
│   └── tests/
│       ├── test_yahoo.rs
│       ├── test_edgar.rs
│       └── test_atomic.rs
│
├── frontend/                            # Bun + TypeScript
│   ├── package.json
│   ├── bun.lockb
│   ├── tsconfig.json
│   ├── src/
│   │   ├── index.ts
│   │   ├── api/
│   │   │   ├── routes.ts
│   │   │   ├── websocket.ts
│   │   │   └── schemas.ts
│   │   ├── db/
│   │   │   ├── duckdb.ts
│   │   │   └── queries.ts
│   │   ├── dashboard/
│   │   │   ├── app.tsx
│   │   │   ├── components/
│   │   │   │   ├── Portfolio.tsx
│   │   │   │   ├── Ledger.tsx           # NEW: NAV and P&L chart
│   │   │   │   ├── TaxLots.tsx          # NEW: lot viewer
│   │   │   │   ├── Predictions.tsx
│   │   │   │   ├── Regime.tsx
│   │   │   │   ├── Locks.tsx
│   │   │   │   └── Orders.tsx
│   │   │   └── charts/
│   │   │       ├── IntervalChart.tsx
│   │   │       ├── NavChart.tsx         # NEW: cumulative return
│   │   │       └── Performance.tsx
│   │   └── lib/
│   │       └── format.ts
│   └── tests/
│       └── api.test.ts
│
├── schemas/                             # Schema registry
│   ├── registry.json
│   └── definitions/
│       ├── panel.md
│       ├── portfolio_ledger.md          # NEW
│       ├── tax_lots.md                  # NEW
│       └── ...
│
├── migrations/                          # Schema change history
│   ├── 2026-10-10-initial.md
│   └── 2026-10-10-tax-lots-partial-close.md   # NEW
│
├── data/                                # Local dev data (gitignored)
│   └── .gitkeep
│
├── scripts/                             # Cross-language tooling
│   ├── session-start.sh
│   ├── pre-commit-constitution.sh
│   ├── verify-schemas.sh
│   ├── generate-registry.jl
│   ├── train-gspqr.jl
│   ├── calibrate.jl
│   ├── fit-tails.jl
│   ├── fit-regime.jl
│   ├── compute-overlay.jl
│   ├── optimize-portfolio.jl
│   ├── run-backtest.jl
│   ├── roundtrip-test.jl
│   ├── reconcile-positions.jl
│   ├── write-ledger.jl                  # NEW
│   └── update-lots.rs                   # NEW
│
├── docker/                              # Unraid deployment
│   ├── quant-core/
│   │   └── Dockerfile                   # Julia + Rust
│   ├── quant-api/
│   │   └── Dockerfile                   # Bun
│   ├── duckdb/
│   │   └── Dockerfile
│   └── compose.yaml
│
├── config/                              # Runtime configuration
│   ├── default.toml
│   ├── production.toml                  # gitignored
│   └── schwab.example.toml
│
├── .github/
│   └── workflows/
│       ├── ci.yml
│       ├── constitution.yml
│       └── backtest.yml
│
├── .gitignore
├── .editorconfig
├── README.md
└── CLAUDE.md
```

---

## What Changed From the Previous Scaffold

Five additions, all driven by the ledger skill:

| Addition | Location | Purpose |
|---|---|---|
| `ledger/` Julia module | Top-level | Daily ledger writes, drawdown, Sortino, YTD realized P&L |
| `execution/src/lots/` | Inside Rust execution crate | FIFO lot matching on fills |
| `Ledger.tsx` and `TaxLots.tsx` | `frontend/src/dashboard/components/` | Dashboard views for NAV and lot history |
| `NavChart.tsx` | `frontend/src/dashboard/charts/` | Cumulative return visualization |
| Two new migration files | `migrations/` | Initial and tax-lot-partial-close |

Plus the two test files (`lot_fifo.rs`, `lot_partial_close.rs`) and the two scripts (`write-ledger.jl`, `update-lots.rs`).

---

## Language Boundaries (Updated)

| Directory | Language | Purpose |
|---|---|---|
| `models/`, `features/`, `portfolio/`, `regime/`, `conviction/`, `ledger/`, `backtest/` | Julia | Analytics, model training, calibration, portfolio construction, ledger |
| `execution/`, `ingest/` | Rust | Execution hot path, data ingestion, event bus, risk checks, lot tracking |
| `frontend/` | Bun/TypeScript | Dashboard, API, visualization |
| `schemas/`, `migrations/`, `scripts/` | Mixed | Cross-language tooling and data contracts |
| `docker/` | YAML/Dockerfile | Unraid deployment |

The `ledger/` module is Julia because it computes metrics (drawdown, Sortino, cumulative return) and is not on the hot path. The `execution/src/lots/` module is Rust because lot matching happens on every fill, which is in the execution path.

---

## Build Order (Updated)

| Phase | Directories Created | Skills Implemented |
|---|---|---|
| **Foundation** | `.claude/skills/`, `schemas/`, `migrations/`, `scripts/` | `00`, `15`, `13` |
| **Ingestion** | `ingest/` | `01` |
| **Panel** | `features/` | `02` |
| **Prediction** | `models/` | `03`, `04`, `05` |
| **Bridge** | `execution/src/inference/`, `execution/src/data/` | `12` |
| **Execution** | `execution/src/schwab/`, `execution/src/locks/`, `execution/src/eventbus/` | `10`, `11`, `09` |
| **Portfolio** | `portfolio/`, `regime/`, `conviction/` | `06`, `07`, `08` |
| **Ledger** | `ledger/`, `execution/src/lots/` | `16` |
| **Frontend** | `frontend/` | (dashboard only) |
| **Evaluation** | `backtest/` | `14` |
| **Deployment** | `docker/`, `config/` | Unraid |

The ledger phase comes after execution because the ledger consumes fills. It comes before the frontend because the dashboard displays ledger data.

---

## Files That Cross Boundaries (Updated)

Four files now cross boundaries and deserve explicit placement:

| File | Location | Purpose |
|---|---|---|
| `schemas/registry.json` | Top-level | Every writer reads it; CI verifies it |
| `models/registry.json` | `models/` | Julia writes it; Rust reads it for inference |
| `execution/src/data/arrow_ipc.rs` | Rust | The Arrow schema shared with Julia |
| `execution/src/lots/types.rs` | Rust | The `TaxLot` struct, mirrored by Julia's `ledger/src/` readers |

The `TaxLot` struct definition must match the Arrow schema in `schemas/definitions/tax_lots.md`. Both sides read the schema before serializing or deserializing. A schema mismatch is a hard failure.

---

## First Files to Write

The order remains the same, with two additions at the end:

1. `schemas/registry.json` — initial empty registry.
2. `schemas/definitions/panel.md` — first schema, matches `13-parquet-lake/SCHEMAS.md` §5.
3. `schemas/definitions/portfolio_ledger.md` — ledger schema, matches `16-portfolio-ledger` §schema.
4. `schemas/definitions/tax_lots.md` — lot schema.
5. `scripts/pre-commit-constitution.sh`.
6. `scripts/session-start.sh`.
7. `migrations/2026-10-10-initial.md`.
8. `ingest/Cargo.toml` and `ingest/src/main.rs` — first production crate.