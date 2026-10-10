#!/usr/bin/env julia
# Writes one row to portfolio_ledger.parquet for a given date.
# Runs at 16:25 ET after reconciliation.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "Statistics"])

using Parquet2
using DataFrames
using Dates
using Statistics

# ---- Configuration ----
const POSITIONS_PATH = get(ENV, "POSITIONS_PATH",
    "/mnt/cache/quant/lake/positions.parquet")
const LEDGER_PATH = get(ENV, "LEDGER_PATH",
    "/mnt/cache/quant/lake/portfolio_ledger.parquet")
const LOTS_PATH = get(ENV, "LOTS_PATH",
    "/mnt/cache/quant/lake/tax_lots.parquet")
const REGIME_PATH = get(ENV, "REGIME_PATH",
    "/mnt/cache/quant/lake/regime_states.parquet")

# ---- Read helpers ----
function read_positions(date::Date)::DataFrame
    df = DataFrame(Parquet2.read(POSITIONS_PATH))
    return filter(r -> r.shares > 0, df)
end

function read_cash_balance(date::Date)::Float64
    # In production: read from Schwab account endpoint
    # For now, look at audit log or a cash parquet file
    return 0.0  # placeholder
end

function read_previous_ledger_row(date::Date)
    if !isfile(LEDGER_PATH)
        return nothing
    end
    df = DataFrame(Parquet2.read(LEDGER_PATH))
    prior = filter(r -> r.date < date, df)
    if nrow(prior) == 0
        return nothing
    end
    return prior[argmax(prior.date), :]
end

function read_first_ledger_value()
    if !isfile(LEDGER_PATH)
        return nothing
    end
    df = DataFrame(Parquet2.read(LEDGER_PATH))
    if nrow(df) == 0
        return nothing
    end
    return df[argmin(df.date), :total_value]
end

function read_regime_factor(date::Date)::Float64
    if !isfile(REGIME_PATH)
        return 1.0
    end
    df = DataFrame(Parquet2.read(REGIME_PATH))
    row = filter(r -> r.date == date, df)
    return nrow(row) == 0 ? 1.0 : row.regime_factor[1]
end

# ---- Compute metrics ----
function sum_realized_today(date::Date)::Float64
    if !isfile(LOTS_PATH)
        return 0.0
    end
    df = DataFrame(Parquet2.read(LOTS_PATH))
    today = filter(r -> !ismissing(r.close_date) && r.close_date == date, df)
    return isempty(today) ? 0.0 : sum(skipmissing(today.realized_pnl))
end

function sum_realized_ytd(date::Date)::Float64
    if !isfile(LOTS_PATH)
        return 0.0
    end
    df = DataFrame(Parquet2.read(LOTS_PATH))
    year_start = Date(year(date), 1, 1)
    ytd = filter(r -> !ismissing(r.close_date) &&
                      r.close_date >= year_start &&
                      r.close_date <= date, df)
    return isempty(ytd) ? 0.0 : sum(skipmissing(ytd.realized_pnl))
end

function compute_trailing_drawdown(current_value::Float64)::Float64
    if !isfile(LEDGER_PATH)
        return 0.0
    end
    df = DataFrame(Parquet2.read(LEDGER_PATH))
    trailing = filter(r -> r.date >= today() - Day(252), df)
    if nrow(trailing) == 0
        return 0.0
    end
    peak = max(maximum(trailing.total_value), current_value)
    return (current_value - peak) / peak
end

# ---- Write ----
function write_ledger_row(date::Date)
    positions = read_positions(date)
    cash = read_cash_balance(date)
    prev = read_previous_ledger_row(date)

    market_value = sum(positions.market_value)
    total_value = cash + market_value
    cost_basis = sum(positions.avg_cost .* positions.shares)
    unrealized = market_value - cost_basis

    daily_return = prev === nothing ? 0.0 :
                   (total_value / prev.total_value) - 1.0

    first_value = read_first_ledger_value()
    cumulative_return = first_value === nothing ? 0.0 :
                        (total_value / first_value) - 1.0

    max_dd = compute_trailing_drawdown(total_value)

    row = DataFrame(
        date = [date],
        cash = [cash],
        cash_pct = [cash / total_value],
        market_value = [market_value],
        total_value = [total_value],
        cost_basis = [cost_basis],
        unrealized_pnl = [unrealized],
        realized_pnl_today = [sum_realized_today(date)],
        realized_pnl_ytd = [sum_realized_ytd(date)],
        n_positions = [nrow(positions)],
        daily_return = [daily_return],
        cumulative_return = [cumulative_return],
        max_drawdown = [max_dd],
        sortino_252d = [0.0],  # computed separately
        regime_factor = [read_regime_factor(date)],
        reconciled = [true],
        backfilled = [false],
    )

    # Append to ledger (in production: idempotent check first)
    if isfile(LEDGER_PATH)
        existing = DataFrame(Parquet2.read(LEDGER_PATH))
        if any(existing.date .== date)
            @warn "Ledger row for $date already exists. Overwriting."
            existing = filter(r -> r.date != date, existing)
            combined = vcat(existing, row)
            Parquet2.write(LEDGER_PATH, combined)
        else
            combined = vcat(existing, row)
            Parquet2.write(LEDGER_PATH, combined)
        end
    else
        Parquet2.write(LEDGER_PATH, row)
    end

    @info "Wrote ledger row for $date"
end

# ---- Main ----
function main()
    date = length(ARGS) >= 2 && ARGS[1] == "--date" ?
           Date(ARGS[2]) : today()

    @info "Writing ledger for $date"
    write_ledger_row(date)
end

main()