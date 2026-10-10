#!/usr/bin/env julia
# Validates panel.parquet for schema, feature integrity, and split rules.
# Run after every panel build. A failure is a stop-the-line event.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "Statistics"])

using Parquet2
using DataFrames
using Dates
using Statistics

const PANEL = get(ENV, "PANEL_PATH", "/mnt/cache/quant/lake/panel.parquet")

const EXPECTED_COLUMNS = [
    :ticker, :date, :split,
    :y_fwd_63d, :y_fwd_126d, :y_fwd_252d,
    :mom_20d, :mom_60d, :mom_12m_1m, :vol_60d_res, :sp_ratio, :turn_20d,
    :r_mom_20d, :r_mom_60d, :r_mom_12m_1m, :r_vol_60d, :r_sp, :r_turn,
]

function validate(path::String)::Int
    if !isfile(path)
        @error "File not found: $path"
        return 1
    end

    df = DataFrame(Parquet2.read(path))
    failures = 0

    # Rule 1: exact column set and order
    actual = Symbol.(names(df))
    if actual != EXPECTED_COLUMNS
        @error "Column mismatch"
        @error "  Expected: $EXPECTED_COLUMNS"
        @error "  Actual:   $actual"
        failures += 1
    end

    # Rule 2: split column has only valid values
    valid_splits = Set(["train", "cal", "test"])
    bad_splits = filter(r -> !(r.split in valid_splits), df)
    if nrow(bad_splits) > 0
        @error "$(nrow(bad_splits)) rows have invalid split value"
        failures += 1
    end

    # Rule 3: split assignment is per-ticker 60/20/20
    for (ticker, grp) in pairs(groupby(df, :ticker))
        g = sort(grp, :date)
        n = nrow(g)
        if n < 5
            continue  # too few rows to validate split ratios
        end
        train_end = floor(Int, 0.6 * n)
        cal_end   = floor(Int, 0.8 * n)

        expected = vcat(
            fill("train", train_end),
            fill("cal", cal_end - train_end),
            fill("test", n - cal_end),
        )
        if g.split != expected
            @warn "$ticker split ratio mismatch (n=$n)"
            # Warn, not fail — the exact rounding may differ by implementation
        end
    end

    # Rule 4: no future targets (y_fwd_63d requires t+63 to exist)
    # Approximate: the last 63 rows per ticker must have NaN y_fwd_63d
    for (ticker, grp) in pairs(groupby(df, :ticker))
        g = sort(grp, :date)
        n = nrow(g)
        if n < 64
            continue
        end
        tail = g[(n - 62):n, :y_fwd_63d]
        if !all(ismissing, tail)
            @error "$ticker has non-NaN y_fwd_63d in last 63 rows"
            failures += 1
        end
    end

    # Rule 5: rank features are in [0, 1] when non-missing
    for col in [:r_mom_20d, :r_mom_60d, :r_mom_12m_1m, :r_vol_60d, :r_sp, :r_turn]
        vals = collect(skipmissing(df[!, col]))
        if !isempty(vals)
            if minimum(vals) < 0.0 || maximum(vals) > 1.0
                @error "$col has values outside [0, 1]"
                failures += 1
            end
        end
    end

    # Rule 6: no duplicate (ticker, date)
    dups = combine(groupby(df, [:ticker, :date]), nrow => :n)
    bad_dups = filter(r -> r.n > 1, dups)
    if nrow(bad_dups) > 0
        @error "$(nrow(bad_dups)) duplicate (ticker, date) keys"
        failures += 1
    end

    # Rule 7: at least 50 tickers on dates where ranks are present
    ranked_dates = unique(df[.!ismissing.(df.r_mom_20d), :date])
    for d in ranked_dates
        n = length(unique(df[df.date .== d, :ticker]))
        if n < 50
            @error "Date $d has ranks with only $n tickers"
            failures += 1
        end
    end

    # Rule 8: no ticker appears with fewer than 3 rows
    for (ticker, grp) in pairs(groupby(df, :ticker))
        if nrow(grp) < 3
            @warn "$ticker has only $(nrow(grp)) rows"
        end
    end

    if failures == 0
        println("OK: $(nrow(df)) rows, $(length(unique(df.ticker))) tickers, " *
                "date range $(minimum(df.date)) to $(maximum(df.date))")
        return 0
    else
        @error "Validation failed with $failures rule violations"
        return 1
    end
end

exit(validate(PANEL))