#!/usr/bin/env julia
# Validates fundamentals.parquet for point-in-time integrity.
# Run after every ingestion job. A failure is a stop-the-line event.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates"])

using Parquet2
using DataFrames
using Dates

const FUNDAMENTALS = get(ENV, "FUNDAMENTALS_PATH",
                          "/mnt/cache/quant/lake/fundamentals.parquet")

function validate(path::String)::Int
    if !isfile(path)
        @error "File not found: $path"
        return 1
    end

    df = DataFrame(Parquet2.read(path))
    failures = 0

    # Rule 1: filing_date must be >= period_end
    # Exception: some filings legitimately have filing_date == period_end
    # for same-day filings. Flag only filing_date < period_end.
    bad1 = filter(r -> r.filing_date < r.period_end, df)
    if nrow(bad1) > 0
        @error "$(nrow(bad1)) rows have filing_date < period_end"
        for r in eachrow(first(bad1, 5))
            @error "  $(r.ticker) filed $(r.filing_date) for period ending $(r.period_end)"
        end
        failures += 1
    end

    # Rule 2: no filing_date in the future
    today = Dates.today()
    bad2 = filter(r -> r.filing_date > today, df)
    if nrow(bad2) > 0
        @error "$(nrow(bad2)) rows have filing_date in the future"
        failures += 1
    end

    # Rule 3: every ticker has at least one filing per quarter it existed
    # (Approximation: check that gaps between consecutive filings
    # are no more than 120 days for each ticker.)
    for (ticker, grp) in pairs(groupby(df, :ticker))
        g = sort(grp, :filing_date)
        gaps = diff(g.filing_date)
        long_gaps = filter(>(120), Dates.value.(gaps))
        if !isempty(long_gaps)
            @warn "$(ticker) has $(length(long_gaps)) gaps > 120 days"
        end
    end

    # Rule 4: every row has a non-null filing_date
    null_filing = filter(r -> ismissing(r.filing_date), df)
    if nrow(null_filing) > 0
        @error "$(nrow(null_filing)) rows have null filing_date"
        failures += 1
    end

    # Rule 5: no duplicate (ticker, filing_date, form_type)
    dups = combine(groupby(df, [:ticker, :filing_date, :form_type]),
                   nrow => :n)
    bad5 = filter(r -> r.n > 1, dups)
    if nrow(bad5) > 0
        @error "$(nrow(bad5)) duplicate (ticker, filing_date, form_type) keys"
        failures += 1
    end

    if failures == 0
        println("OK: $(nrow(df)) rows validated across $(length(unique(df.ticker))) tickers")
        return 0
    else
        @error "Validation failed with $failures rule violations"
        return 1
    end
end

exit(validate(FUNDAMENTALS))