# Retry Policy

Every external fetch can fail. The policy is the same across sources,
with per-source backoff constants.

## The Algorithm

    attempt = 1
    backoff = base_backoff
    while attempt <= max_attempts:
        response = fetch()
        if response.ok:
            return response
        if response.status in (400, 401, 403, 404):
            log_fail(no_retry)
            return error
        if response.status == 429:
            sleep(rate_limit_backoff)
            attempt += 1
            continue
        if response.status >= 500:
            sleep(backoff)
            backoff *= 2
            attempt += 1
            continue
        if response.timeout:
            sleep(backoff)
            backoff *= 2
            attempt += 1
            continue
    log_fail(max_attempts_exceeded)
    return error

## Constants Per Source

| Source | Base backoff | Max attempts | Rate-limit backoff |
|---|---|---|---|
| Yahoo | 2s | 3 | 60s |
| SEC EDGAR | 1s | 5 | 60s |
| FRED | 1s | 3 | 120s |
| iShares | 5s | 2 | 300s |

Backoff is exponential: 1s, 2s, 4s, 8s, 16s. Capped at 60s.

## Non-Retryable Failures

- HTTP 4xx (except 429)
- Schema mismatch (the response is valid JSON but not the shape we expect)
- Empty response for a source that should always have data
- EDGAR filing that parses but is malformed XBRL (log, skip, alert)

## Retryable Failures

- HTTP 5xx
- HTTP 429
- Timeout
- Connection refused
- TLS handshake failure

## Escalation

When retries are exhausted:

1. Log `FAIL` in `data_quality.parquet` with the source, dataset, and
   attempt count.
2. Write a `CRITICAL` row to `audit_log.parquet`.
3. Exit the ingestion job non-zero.
4. The scheduler is responsible for alerting.

The system does not retry after a scheduled run completes. The next
scheduled run will attempt again. If a source has been failing for more
than 3 consecutive runs, the alert should escalate to manual review.

## Special Case: SEC Filings

SEC filings are the hardest to retry correctly.

- **Filing not yet available:** If a company was expected to file on
  2024-02-15 but the filing is not on EDGAR, retry in 1 hour, up to 3
  times that day. Then wait for the next scheduled run.
- **Filing available but XBRL malformed:** Log WARN, skip, retry in 4
  hours. Do not block other tickers.
- **Filing not yet accepted but filed:** SEC sometimes has a window
  between submission and acceptance. The `acceptance_datetime` is the
  authoritative timestamp. If missing, wait and retry.

## Logging

Every retry logs:

    [WARN] ingest_prices ticker=AAPL attempt=2 reason=timeout backoff=4s

Every exhausted retry logs:

    [FAIL] ingest_prices ticker=AAPL attempts=3 reason=timeout

These lines go to the container log and to `data_quality.parquet`.

## What Not to Do

- Do not retry on 4xx. The request is wrong; retrying makes it wrong
  again.
- Do not use a fixed backoff. Exponential prevents thundering herds.
- Do not retry forever. Bounded attempts, then escalate.
- Do not silently swallow failures. Every failed fetch is logged.
- Do not retry on a shorter schedule than the source's update cadence.
  Yahoo does not update mid-day. Retrying every 5 minutes wastes calls.