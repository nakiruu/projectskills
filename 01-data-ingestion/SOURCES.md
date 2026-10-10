# Source Details

Per-source API patterns, auth, and known quirks.

---

## Yahoo Finance

**Client:** `yfinance` (Python) for prototyping, `yahoo-finance-rs` or a
direct HTTP client for production Rust.

**Endpoints used:**
- `Ticker.history(period, interval, auto_adjust=True)` — OHLCV
- `Ticker.info` — snapshot fundamentals (stamp at fetch time)
- `Ticker.calendar` — earnings dates

**Key rules:**
- `auto_adjust=True` for all price history. Splits and dividends already
  applied in the returned values.
- `info` is a snapshot, not a time series. Store with a `fetch_date` column.
- `history` returns rows indexed by date. Ensure timezone is UTC before
  writing to Parquet.
- Yahoo occasionally returns `NaN` for `close` on a trading day. Drop
  those rows and log WARN.

**Rate limit:** informal. Treat 100 requests per 2 minutes as safe.

**Known issues:**
- Intermittent 429s under load. Back off 60s, retry once.
- Occasional data errors (e.g., 10x price spikes). Sanity-check
  `high >= low` and `close` within `[low, high]`. Drop and log if violated.
- Earnings dates sometimes shift. Re-fetch weekly.

**Code pattern (Rust):**

```rust
async fn fetch_prices(ticker: &str, start: NaiveDate, end: NaiveDate)
    -> Result<Vec<PriceRow>, IngestError>
{
    let _permit = YAHOO_SEMAPHORE.acquire().await?;
    let url = format!(
        "https://query1.finance.yahoo.com/v8/finance/chart/{}?period1={}&period2={}&interval=1d",
        ticker,
        start.and_hms_opt(0, 0, 0).unwrap().timestamp(),
        end.and_hms_opt(0, 0, 0).unwrap().timestamp(),
    );
    let resp = HTTP.get(&url).timeout(Duration::from_secs(30)).send().await?;
    // ... parse JSON, extract OHLCV, validate, return
}
```

---

## SEC EDGAR

**Client:** `edgartools` (Python) for prototyping, direct XBRL API for Rust.

**Auth:** Set `User-Agent` header to `"<ProjectName> <email>"`. Required by
SEC. Requests without it are blocked.

**Endpoints used:**
- `https://data.sec.gov/api/xbrl/companyconcept/CIK{cik}/us-gaap/{tag}.json`
- `https://data.sec.gov/submissions/CIK{cik}.json`
- `https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&...`

**XBRL tags used:**

| Data point | XBRL tag |
|---|---|
| Revenues | `RevenueFromContractWithCustomerExcludingAssessedTax` |
| Net income | `NetIncomeLoss` |
| Total assets | `Assets` |
| Total liabilities | `Liabilities` |
| Operating cash flow | `NetCashProvidedByUsedInOperatingActivities` |
| Gross profit | `GrossProfit` |
| Current assets | `AssetsCurrent` |
| Current liabilities | `LiabilitiesCurrent` |
| Long-term debt | `LongTermDebtNoncurrent` |
| Retained earnings | `RetainedEarningsAccumulatedDeficit` |
| EBIT | `OperatingIncomeLoss` |
| Shares outstanding | `CommonStockSharesOutstanding` |

Tags vary by company. Always query multiple candidate tags and take the
first non-null. Log which tag was used.

**Key rules:**
- The `filing_date` from the submissions endpoint is the point-in-time
  stamp. The `end` date in the XBRL concept is `period_end`. Never confuse
  them.
- 10-Q filed 2024-02-15 for period ending 2023-12-31: `filing_date` is
  2024-02-15, `period_end` is 2023-12-31.
- Amended filings (10-Q/A) restate. Store both. The panel uses the latest
  filing_date as of the decision date.

**Rate limit:** SEC allows 10 requests/second. This is a hard limit.
Enforce with a token bucket. Violations may result in a temporary IP ban.

**Code pattern (Rust):**

```rust
async fn fetch_filing(cik: &str, accession: &str)
    -> Result<FilingData, IngestError>
{
    let _permit = SEC_SEMAPHORE.acquire().await?;
    let url = format!(
        "https://data.sec.gov/api/xbrl/companyconcept/CIK{}/us-gaap/Revenues.json",
        cik
    );
    let resp = HTTP
        .get(&url)
        .header("User-Agent", &SEC_USER_AGENT)
        .timeout(Duration::from_secs(60))
        .send()
        .await?;
    // ... parse, filter by filing_date, extract most recent before now
}
```

---

## FRED

**Client:** `fredapi` (Python) or direct HTTP in Rust.

**Auth:** Free API key from https://fredaccount.stlouisfed.org/apikey. Set
`FRED_API_KEY` in the environment.

**Series used:**

| Series ID | Column name | Native cadence | Release lag |
|---|---|---|---|
| `DGS3MO` | `treasury_3m` | Daily | Same day, 16:15 ET |
| `DGS2` | `treasury_2y` | Daily | Same day |
| `DGS10` | `treasury_10y` | Daily | Same day |
| `BAMLH0A0HYM2` | `hy_credit_spread` | Daily | Same day |
| `BAMLC0A0CM` | `ig_credit_spread` | Daily | Same day |
| `CPIAUCSL` | `cpi` | Monthly | ~2 weeks after month-end |
| `FEDFUNDS` | `fed_funds_rate` | Monthly | ~1 week after month-end |
| `UNRATE` | `unemployment_rate` | Monthly | First Friday after month-end |
| `VIXCLS` | `vix` | Daily | Same day |

**Key rules:**
- FRED returns observation dates. For monthly series, the value for
  `2024-01-01` reflects January. It was not published until ~2024-02-13
  (CPI).
- Use the release date, not the observation date, for point-in-time.
  The FRED API's `releases` endpoint gives the release date.
- If release dates are unavailable, apply the buffer table in
  `POINT-IN-TIME.md`.
- Forward-fill from release date forward. Do not forward-fill backward.

**Rate limit:** 120 requests/minute. Token bucket with refill 2/sec.

**Code pattern (Julia, prototyping):**

```julia
using FredApi  # or HTTP.jl direct

function fetch_series(series_id::String, start::Date, enddate::Date)
    fred = Fred(ENV["FRED_API_KEY"])
    s = get_series(fred, series_id;
                   observation_start = start, observation_end = enddate)
    # Returns DataFrame with :date, :value
    # Join to release dates separately
    return s
end
```

---

## iShares

**Source:** iShares publishes holdings CSVs at predictable URLs.

**URLs:**
- IWF: `https://www.ishares.com/us/products/239714/ishares-russell-1000-growth-etf/1467271812596.ajax?fileType=csv&fileName=IWF_holdings&dataType=fund`
- IWP: similar pattern, different product ID
- IJT: similar pattern

**Key rules:**
- Fetch monthly. Holdings change slowly.
- The CSV has a header block before the actual data. Skip until the row
  containing `Ticker,Name,Sector,...`.
- The `as of` date in the header is the effective date. Use it, not the
  fetch date.
- Some rows have `-` for ticker (cash, futures). Filter them.
- Some tickers have suffixes (`.A`, `.B`) for share classes. Normalize.

**Rate limit:** iShares serves these as static files. One fetch per day is
polite. Do not hammer.

**Code pattern (Rust):**

```rust
async fn fetch_holdings(etf: &str) -> Result<Vec<Holding>, IngestError> {
    let _permit = ISHARES_SEMAPHORE.acquire().await?;
    let url = match etf {
        "IWF" => "...",
        "IWP" => "...",
        "IJT" => "...",
        _ => return Err(IngestError::UnknownEtf),
    };
    let resp = HTTP.get(url).timeout(Duration::from_secs(60)).send().await?;
    let text = resp.text().await?;
    // Skip header rows until we find the column header
    // Parse CSV, filter out cash/futures
    // Extract effective date from the header
}
```

---

## Common Patterns

**Last-successful-date check:**

```rust
async fn last_successful_date(file: &Path) -> Result<Option<NaiveDate>, IngestError> {
    if !file.exists() {
        return Ok(None);
    }
    // For partitioned files, read the max date across partitions.
    // For single files, read the max date column.
    // Use Polars or Arrow for efficiency.
}
```

**Atomic write:**

```rust
async fn atomic_write<T: Serialize>(rows: &[T], target: &Path)
    -> Result<(), IngestError>
{
    let tmp = target.with_extension(format!("tmp.{}", timestamp_now()));
    write_parquet(rows, &tmp).await?;
    tokio::fs::rename(&tmp, target).await?;
    Ok(())
}
```

**Data quality log:**

```rust
async fn log_quality(
    source: &str, dataset: &str,
    expected: usize, received: usize,
    status: QualityStatus, notes: Option<&str>,
) -> Result<(), IngestError> {
    let row = QualityRow {
        date: today(),
        source: source.into(),
        dataset: dataset.into(),
        tickers_expected: expected as i32,
        tickers_received: received as i32,
        missing_pct: (expected - received) as f64 / expected as f64 * 100.0,
        latency_min: 0,
        status,
        notes: notes.map(String::from),
    };
    append_to_parquet("data_quality.parquet", &row).await
}
```

All ingestion follows these three patterns. Deviating means re-explaining
the pattern in code review. Do not deviate.
