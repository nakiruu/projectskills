---
name: parquet-lake
description: The data lake. Every Parquet file in the system, its schema,
  partitioning, and query patterns. Load whenever touching any .parquet
  file, DuckDB query, schema definition, or migration.
---

# Parquet Lake

The lake is 21 files. Their schemas are frozen once written (constitution
§5). This skill is the authoritative definition of each.

## 1. Storage Principles

- **Format:** Apache Parquet, ZSTD compression, level 3.
- **Partitioning:** Large daily files are partitioned by `year/month`.
  Small or event-driven files are single-file.
- **Naming:** `snake_case.parquet`. No version suffixes in the filename.
- **Location:** All live files on the cache pool. Never on the array.
  See `UNRAID-STORAGE.md`.
- **Ownership:** Written by exactly one module. Read by many. The writer
  is documented in `SCHEMAS.md`.

## 2. Schema Immutability

Once a schema is committed and used, it is frozen. The rules:

- **Additive only.** New columns append to the right. No insertion.
- **No renames.** A rename is a new column plus a deprecation of the old.
- **No retypes.** Changing `float32` to `float64` requires a migration.
- **No reorders.** Column order is part of the schema hash.

Every schema has a SHA-256 hash stored in `schemas/registry.json`. A CI
job verifies that each file's schema matches its registered hash. Mismatch
without a migration file is a build failure.

See `MIGRATIONS.md` for the additive change procedure.

## 3. The 21 Files

Full schemas in `SCHEMAS.md`. The one-line summary:

| # | File | Written by | Update |
|---|---|---|---|
| 1 | `universe.parquet` | Julia (universe builder) | Monthly |
| 2 | `prices.parquet` | Rust (ingest) | Daily |
| 3 | `fundamentals.parquet` | Rust (ingest) | Event (filing) |
| 4 | `macro.parquet` | Rust (ingest) | Daily |
| 5 | `panel.parquet` | Julia (feature engine) | Daily |
| 6 | `regime_states.parquet` | Julia (regime) | Daily |
| 7 | `gspqr_predictions.parquet` | Julia (GSPQR) | Daily |
| 8 | `tcp_calibration.parquet` | Julia (TCP) | Daily |
| 9 | `evt_residuals.parquet` | Julia (EVT) | Daily |
| 10 | `evt_tail_bounds.parquet` | Julia (EVT) | Daily |
| 11 | `conviction_scores.parquet` | Julia (conviction) | Event + daily |
| 12 | `veto_flags.parquet` | Julia (conviction) | Event + daily |
| 13 | `portfolio_targets.parquet` | Julia (portfolio) | Event-driven |
| 14 | `position_locks.parquet` | Rust (lock monitor) | Event-driven |
| 15 | `pending_orders.parquet` | Rust (order manager) | Event-driven |
| 16 | `orders.parquet` | Rust (execution) | Event-driven |
| 17 | `positions.parquet` | Rust (execution) | Daily |
| 18 | `fills.parquet` | Rust (execution) | Event-driven |
| 19 | `evaluation_metrics.parquet` | Julia (backtest) | Daily |
| 20 | `data_quality.parquet` | Rust (ingest) | Daily |
| 21 | `audit_log.parquet` | Rust (event bus) | Event-driven |

**Single-writer rule.** No file has more than one writer. If two modules
need to write the same data, they write two files. This eliminates write
contention and makes the data lineage unambiguous.

## 4. Partitioning

| File | Partition scheme | Rationale |
|---|---|---|
| `prices.parquet` | `year=YYYY/month=MM/` | ~800K rows, daily queries by date range |
| `panel.parquet` | `year=YYYY/month=MM/` | ~800K rows, daily queries by date range |
| `gspqr_predictions.parquet` | `year=YYYY/month=MM/` | ~500K rows, daily queries |
| `tcp_calibration.parquet` | `year=YYYY/month=MM/` | ~500K rows |
| `evt_residuals.parquet` | `year=YYYY/month=MM/` | ~500K rows |
| `conviction_scores.parquet` | Single file | ~150K rows, quarterly updates |
| All others | Single file | Small enough (< 50K rows) |

Partitioning is Hive-style. DuckDB and Polars read it natively. Do not
partition on `ticker`; the universe changes over time and the resulting
directory churn is not worth it.

## 5. Reading and Writing

**Julia:**
- Write: `Arrow.write` then `Parquet2.write` (or `Parquet.jl` when stable).
- Read: `Parquet2.read` or `Arrow.Table(Arrow.tobuffer(...))`.
- Never use CSV as an intermediate format. Arrow IPC or Parquet only.

**Rust:**
- Write: `parquet::arrow::ArrowWriter` with `Compression::ZSTD(3)`.
- Read: `parquet::arrow::ParquetRecordBatchReaderBuilder`.
- Use `polars` for transformations. Use `arrow` for the file I/O boundary.
- Never hold a file open across an async boundary. Read, process, close.

**Bun/DuckDB:**
- Read-only. All queries via `@nshiab/simple-data-analysis-core`.
- Never write to the lake from Bun. Writes go through Julia or Rust.

## 6. Schema Registry

`schemas/registry.json` maps each filename to a SHA-256 hash of its schema.

```json
{
  "prices.parquet": {
    "hash": "a3f9...",
    "columns": 8,
    "partitioned": true,
    "writer": "rust-ingest",
    "last_migration": "2026-10-10-initial"
  },
  "...": {}
}

Update procedure when adding a column:

    Edit the writer to include the new column.

    Run scripts/generate-registry.jl to recompute hashes.

    Add a migration file in migrations/.

    Commit all three together.

CI verifies the hashes match. See MIGRATIONS.md.
7. Query Patterns

See QUERY-PATTERNS.md. The three most common:

    Latest prediction for a ticker: filter date == max(date) on
    gspqr_predictions.parquet, then join to tcp_calibration.parquet and
    evt_tail_bounds.parquet on (ticker, date, horizon).

    Lock status for a ticker: read position_locks.parquet, filter by
    ticker, check lock_expiry_date against current_date.

    Eligible universe on a date: read universe.parquet, filter
    effective_date <= date AND (end_date IS NULL OR end_date > date) AND eligible = true, then exclude any ticker with veto_active = true in
    veto_flags.parquet.

Do not write ad-hoc queries against the lake from production code. Those
queries live in Julia or Rust modules and are tested. DuckDB is for
debugging and dashboard.
8. What Not to Do

    Do not write to the array (/mnt/user/). See UNRAID-STORAGE.md.

    Do not create a new Parquet file without updating SCHEMAS.md and
    registry.json in the same commit.

    Do not use float32 for prices or returns. float64 only. The space
    savings are not worth the precision loss.

    Do not store datetimes as strings. Use Arrow timestamp[ns, UTC].

    Do not partition by ticker. Partition by time.

    Do not overwrite a file in place during a query. Write to a temp path,
    then atomic rename.

    Do not read a Parquet file into memory when a predicate pushdown would
    suffice. Filter at the reader.

    Do not use pandas in any Julia or Rust code path. It is not a bridge.

9. Verification

Before committing any change to a Parquet writer:

    □

    Run scripts/verify-schemas.sh and it passes
    □

    If schema changed, registry.json is regenerated
    □

    If schema changed, a migration file exists in migrations/
    □

    The writer's file path is under /mnt/cache/quant/, not the array
    □

    ZSTD level is 3
    □

    Partitioning matches the table in §4
    □

    No column was renamed, retyped, or reordered
    □

    A test reads back the file and asserts the schema

10. Related Skills

    00-constitution §5 — schema immutability rule

    01-data-ingestion — writers for prices, fundamentals, macro

    02-panel-construction — writer for panel

    03-gspqr-model — writer for gspqr_predictions

    04-tcp-calibration — writer for tcp_calibration

    05-evt-tails — writers for evt_residuals, evt_tail_bounds

    10-execution-schwab — writers for orders, fills, positions

    11-rust-event-bus — writer for audit_log

    14-backtest-protocol — writer for evaluation_metrics