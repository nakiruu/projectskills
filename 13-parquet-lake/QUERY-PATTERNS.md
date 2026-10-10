
---

## `QUERY-PATTERNS.md`

```markdown
# Query Patterns

Common DuckDB queries against the lake. Use these for debugging and for
the dashboard. Production queries live in Julia or Rust and are tested.

## Latest Prediction for a Ticker

```sql
WITH latest AS (
  SELECT ticker, MAX(date) AS date
  FROM read_parquet('/data/lake/gspqr_predictions/**/*.parquet')
  WHERE ticker = 'AAPL'
  GROUP BY ticker
)
SELECT
  p.ticker, p.date, p.horizon,
  p.q_05, p.q_50, p.q_95,
  c.q_hat_lower, c.q_hat_upper,
  e.q_extreme
FROM read_parquet('/data/lake/gspqr_predictions/**/*.parquet') p
JOIN latest l ON p.ticker = l.ticker AND p.date = l.date
LEFT JOIN read_parquet('/data/lake/tcp_calibration/**/*.parquet') c
  ON p.ticker = c.ticker AND p.date = c.forecast_date
  AND p.horizon = c.horizon
LEFT JOIN read_parquet('/data/lake/evt_tail_bounds.parquet') e
  ON p.ticker = e.ticker AND p.date = e.fit_date
  AND p.horizon = e.horizon
WHERE p.horizon = '63d';
```

# Lock Status for a Ticker
```sql
SELECT
  ticker, state, lock_expiry_date, shares_held, pending_side,
  CASE
    WHEN lock_expiry_date IS NULL THEN 'unlocked'
    WHEN lock_expiry_date <= current_date THEN 'expired'
    ELSE 'locked'
  END AS lock_status
FROM read_parquet('/data/lake/position_locks.parquet')
WHERE ticker = 'AAPL';
```

# Eligible Universe on a Date
```sql
WITH u AS (
  SELECT ticker
  FROM read_parquet('/data/lake/universe.parquet')
  WHERE effective_date <= DATE '2024-06-14'
    AND (end_date IS NULL OR end_date > DATE '2024-06-14')
    AND eligible = true
),
v AS (
  SELECT ticker
  FROM read_parquet('/data/lake/veto_flags.parquet')
  WHERE as_of_date = DATE '2024-06-14'
    AND veto_active = false
)
SELECT u.ticker
FROM u JOIN v USING (ticker)
ORDER BY u.ticker;
```

# Coverage Over Trailing 60 Days
```sql
WITH joined AS (
  SELECT
    r.ticker, r.date, r.horizon,
    r.realized_return,
    c.q_hat_lower, c.q_hat_upper
  FROM read_parquet('/data/lake/evt_residuals/**/*.parquet') r
  JOIN read_parquet('/data/lake/tcp_calibration/**/*.parquet') c
    ON r.ticker = c.ticker
    AND r.date = c.forecast_date
    AND r.horizon = c.horizon
  WHERE r.date >= current_date - INTERVAL 60 DAY
)
SELECT
  horizon,
  AVG(CASE WHEN realized_return BETWEEN q_hat_lower AND q_hat_upper
      THEN 1.0 ELSE 0.0 END) AS coverage_95
FROM joined
GROUP BY horizon;
```

# Regime Distribution Over Time
```sql
SELECT
  viterbi_state,
  COUNT(*) AS days,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS pct
FROM read_parquet('/data/lake/regime_states.parquet')
WHERE date >= current_date - INTERVAL 252 DAY
GROUP BY viterbi_state
ORDER BY days DESC;
```

# Pending Orders Near Lock Expiry
```sql
SELECT
  pending_id, ticker, side, target_quantity,
  earliest_execution,
  earliest_execution - current_date AS days_until
FROM read_parquet('/data/lake/pending_orders.parquet')
WHERE status = 'Pending'
  AND earliest_execution BETWEEN current_date AND current_date + INTERVAL 5 DAY
ORDER BY earliest_execution;
```

# Veto History for a Ticker
```sql
SELECT
  as_of_date, altman_z, going_concern, veto_active
FROM read_parquet('/data/lake/veto_flags.parquet')
WHERE ticker = 'XYZ'
  AND as_of_date >= current_date - INTERVAL 365 DAY
ORDER BY as_of_date DESC;
```

# Audit Trail for an Order
```sql
SELECT timestamp, event_type, actor, details, severity
FROM read_parquet('/data/lake/audit_log.parquet')
WHERE details LIKE '%o001%'
ORDER BY timestamp;
```

# Anti-Patterns

    Do not SELECT * on partitioned files. Always specify columns. The
    predicate pushdown is real, but column pruning is also real.

    Do not query without a date filter on partitioned files. Reading 5
    years of daily data to answer a "latest" question is wasteful.

    Do not use read_parquet on a specific partition file in production
    code. Use the glob pattern and let DuckDB prune.

    Do not write DDL or DML from DuckDB. The lake is read-only from
    DuckDB's perspective. Writes go through Julia or Rust.