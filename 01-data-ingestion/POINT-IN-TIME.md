# Point-in-Time Discipline

The single most important rule in ingestion. Violating it introduces
lookahead bias that no downstream test can catch.

## The Rule

A data point is usable at decision time `t` only if it was publicly
available on or before `t`. Availability is determined by publication
date, not observation date.

## Per-Source Semantics

### SEC Filings

| Field | Meaning | Use for |
|---|---|---|
| `filing_date` | Date the filing became public on EDGAR | Point-in-time stamp |
| `period_end` | Date the fiscal period ended | Metadata only |
| `acceptance_datetime` | Exact timestamp SEC accepted it | Ultra-precise stamping |

**The 10-Q example:** Filed 2024-02-15 for period ending 2023-12-31.
- Usable starting 2024-02-15.
- Not usable on 2024-02-14, even though the quarter ended 2023-12-31.
- Not usable on 2023-12-31, even though the numbers reflect that period.

**Amended filings:** A 10-Q/A filed 2024-03-01 restates the original.
The original is still usable from its own filing_date. The amended
figures become usable from 2024-03-01. Store both.

### FRED Series

FRED observation dates are the period the data describes, not the date
it was released.

| Series cadence | Observation date | Usable date |
|---|---|---|
| Daily (DGS10) | 2024-01-15 | 2024-01-15, ~16:15 ET |
| Monthly (CPIAUCSL) | 2024-01-01 | ~2024-02-13 (release) |
| Monthly (UNRATE) | 2024-01-01 | ~2024-02-02 (first Friday) |

**If release dates are unavailable,** apply a conservative buffer:

| Series type | Conservative buffer |
|---|---|
| Daily treasury | Same day, after 16:30 ET |
| Daily credit spread | Same day, after 16:30 ET |
| VIX close | Same day, after 16:30 ET |
| Monthly CPI | 45 days after month-end |
| Monthly Fed funds | 30 days after month-end |
| Monthly unemployment | 7 days after month-end |

The buffer is a floor. If the actual release date is earlier, use it.
If it is later, the buffer is wrong and must be updated.

### Yahoo Prices

- **Close on date `t`:** Usable at 16:00 ET on `t`.
- **Open, high, low, volume on `t`:** Usable at 16:00 ET on `t`.
- **`Ticker.info` snapshot:** Usable from the fetch timestamp. Store with
  `fetch_date`. Not a time series.
- **Earnings dates from `Ticker.calendar`:** Usable from fetch. These
  are estimates until confirmed.

### iShares Holdings

- The CSV header contains an "as of" date.
- Use that date, not the fetch date.
- The file is published monthly, usually a few days after month-end.

## Implementation

### In joins

Every join between price data and any other data uses an as-of join:

```sql
-- Correct: as-of join on filing_date
SELECT p.ticker, p.date, f.revenues
FROM prices p
LEFT JOIN fundamentals f
  ON p.ticker = f.ticker
  AND f.filing_date <= p.date
QUALIFY ROW_NUMBER() OVER (
  PARTITION BY p.ticker, p.date
  ORDER BY f.filing_date DESC
) = 1;

-- Wrong: equality join on period_end
SELECT p.ticker, p.date, f.revenues
FROM prices p
LEFT JOIN fundamentals f
  ON p.ticker = f.ticker
  AND f.period_end = p.date;
```

The second query is a lookahead violation. It uses data that was not
public on `p.date`.

### In feature construction

A feature computed "for date `t`" uses only data with availability
date `<= t`. The linter catches `period_end` in decision code, but
ingestion code must set the standard.

### In backtests

The backtest engine reads the ingestion output. If ingestion is correct,
the backtest is correct (with respect to point-in-time). If ingestion
has lookahead, the backtest inherits it and no amount of downstream
testing will catch it.

## Verification

`scripts/validate-filings.jl` scans `fundamentals.parquet` and asserts:

- Every row has `filing_date >= period_end` (filings cannot precede the
  period they describe, except for some edge cases — flagged for review)
- No `filing_date` is in the future relative to the file's max date
- Every `ticker` has at least one filing per quarter it existed

Run it after every ingestion job. A failure is a stop-the-line event.

## What to Do When a New Source Is Added

Before writing any ingestion code for a new source, answer:

1. What is the publication date? Is it provided by the source, or must
   it be inferred?
2. Is the source restated (like SEC amendments) or immutable (like
   completed trading data)?
3. What is the update cadence? Does it match the fetch schedule?
4. What is the failure mode? Does the source silently return stale data,
   or does it error?

Document the answers in this file before writing code. The code should
implement exactly what this file says.
