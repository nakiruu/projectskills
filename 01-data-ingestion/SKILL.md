---
name: data-ingestion
description: Fetching raw data from Yahoo Finance, SEC EDGAR, FRED, and
  iShares. Load when touching ingest/, sources/, or any code importing
  yfinance, edgartools, or fredapi.
---

# Data Ingestion

Four external sources feed this system. Each has different rate limits,
different reliability, and different point-in-time semantics. This skill
documents how to fetch from each without introducing lookahead, without
hammering the source, and without silently producing incomplete data.

## 1. The Four Sources

| Source | Provides | Cadence | Auth | Rate limit |
|---|---|---|---|---|
| Yahoo Finance | Prices, quote snapshots | Daily after close | None | Informal, ~2000/hr |
| SEC EDGAR | Fundamentals (10-Q, 10-K, 8-K) | Event (filing) | Email in UA header | 10 req/sec |
| FRED | Macro series | Daily | Free API key | 120 req/min |
| iShares | ETF holdings CSVs | Monthly | None | Polite, ~1/day |

See `SOURCES.md` for API details and code patterns per source.

## 2. Non-Negotiables

Inherited from the constitution (§2, §3):

- **Every fundamental datum carries its `filing_date`.** The `period_end` is
  metadata. Never a decision variable. The linter catches `period_end` in
  decision code, but the ingestion layer is where this rule is established.
- **No future data.** A fetch on 2024-06-14 cannot return data with a
  timestamp after 2024-06-14. If the source returns such data, drop it.
- **Failures are logged, never silent.** Every failed fetch writes a row
  to `data_quality.parquet` with `status = WARN` or `FAIL`.
- **Idempotent.** Re-running ingestion for the same date produces the same
  output. No partial writes. Write to a temp path, atomic rename.

## 3. Write Targets

Each ingestion job writes exactly one file (see `13-parquet-lake`):

| Job | Writes | Frequency |
|---|---|---|
| `ingest_prices` | `prices.parquet` (partitioned) | Daily |
| `ingest_fundamentals` | `fundamentals.parquet` | On new filing |
| `ingest_macro` | `macro.parquet` | Daily |
| `ingest_universe` | `universe.parquet` | Monthly |

If a job produces no new data (market closed, no new filings), it writes
nothing. Do not append empty rows.

## 4. Fetch Discipline

Every external call follows the same pattern:

1. **Check the last successful fetch.** Read the max date from the target
   file. If the source has nothing newer, skip the call.
2. **Fetch with a bounded timeout.** 30 seconds for HTTP, 60 for EDGAR
   full-text. If the timeout fires, log and retry per `RETRY-POLICY.md`.
3. **Validate the response.** Non-empty, expected schema, no future dates.
   If validation fails, discard and log.
4. **Write to a temp path.** `{target}.tmp.{timestamp}`. Never write in place.
5. **Atomic rename.** `mv temp target`. This is the only write the file
   system sees.
6. **Log to `data_quality.parquet`.** Success or failure, always log.

If any step fails, the job exits non-zero and does not write. The next run
picks up where this one left off. There is no partial-state window.

## 5. Rate Limiting

Every source has a token bucket. Fetch only when the bucket allows.

| Source | Bucket size | Refill rate |
|---|---|---|
| Yahoo | 100 | 1 token per 2 seconds |
| SEC EDGAR | 10 | 1 token per 100 ms |
| FRED | 120 | 2 tokens per second |
| iShares | 5 | 1 token per minute |

Implement with `tokio::sync::Semaphore` in Rust. Do not sleep manually;
use the semaphore. Concurrent fetches are fine up to the bucket limit.

SEC EDGAR requires a `User-Agent` header with a real email address.
Requests without it are rejected. Set `SEC_EDGAR_EMAIL` in the environment.

## 6. Point-in-Time Rules

See `POINT-IN-TIME.md`. The rules in one paragraph:

For SEC data, the `filing_date` is when the information became public.
The `period_end` is when the fiscal period ended. A 10-Q filed on
2024-02-15 for the quarter ending 2023-12-31 becomes usable on
2024-02-15. Before that date, no feature, model, or decision may use it.

For FRED data, the observation date is when the period started (e.g.,
2024-01 for January CPI), but the data was published weeks later. Use
the FRED release date, not the observation date. If unavailable, delay
by a conservative buffer (see `POINT-IN-TIME.md` for the buffer table).

For Yahoo prices, the close on date `t` becomes usable at market close
on `t`, which is 16:00 ET. Any feature computed "for date `t`" uses
prices through `t` and is available after 16:00.

For iShares holdings, the effective date is the file publication date.
Use the CSV's stated date, not the fetch date.

## 7. Handling Failures

| Failure mode | Action |
|---|---|
| HTTP timeout | Retry up to 3 times with exponential backoff |
| HTTP 429 (rate limit) | Back off 60s, retry once |
| HTTP 4xx (except 429) | Do not retry. Log FAIL. |
| HTTP 5xx | Retry up to 5 times with backoff |
| Schema mismatch | Do not retry. Log FAIL. Alert. |
| Future dates in response | Drop those rows. Log WARN. |
| Empty response for known-active source | Log WARN. Retry next scheduled run. |
| EDGAR filing not yet parseable | Log WARN. Retry in 1 hour, up to 3 times. |

All retries are logged with attempt number. A job that exhausts retries
exits non-zero. The scheduler is responsible for alerting.

## 8. What Not to Do

- Do not use `period_end` in any join, filter, or feature computation
  outside of ingestion's own deduplication logic.
- Do not fetch without checking the last-successful date first. Redundant
  fetches waste rate limits and produce no new data.
- Do not write in place. Every write is temp + rename.
- Do not skip the `data_quality.parquet` log. Silent failures are the
  worst kind.
- Do not fetch on a schedule tighter than the source's natural update
  cadence. Yahoo updates once daily. FRED updates on release dates.
- Do not retry indefinitely. Bounded retries, then escalate.
- Do not parse HTML to extract SEC data. Use the XBRL API or `edgartools`.
- Do not trust `Ticker.info` from yfinance as time-series data. It is a
  snapshot. Stamp it at fetch time.

## 9. Verification

Before committing any ingestion change:

- [ ] The fetch checks last-successful date before calling
- [ ] The fetch uses the token bucket for its source
- [ ] Writes are temp + atomic rename
- [ ] The `data_quality.parquet` row is written on both success and failure
- [ ] SEC data uses `filing_date`, never `period_end` for stamping
- [ ] FRED data uses release date, not observation date
- [ ] Future-dated rows are dropped
- [ ] Re-running the job produces identical output
- [ ] A test mocks the source and asserts idempotency
- [ ] A test asserts failures are logged

## 10. Related Skills

- `00-constitution` §2, §3 — point-in-time and no-lookahead rules
- `13-parquet-lake` — target schemas and write patterns
- `02-panel-construction` — consumes ingestion output
- `14-backtest-protocol` — depends on correct point-in-time discipline