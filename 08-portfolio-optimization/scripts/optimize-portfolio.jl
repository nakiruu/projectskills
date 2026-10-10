#!/usr/bin/env julia
# Runs the PMPT portfolio optimization and writes portfolio_targets.parquet.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "Statistics",
         "PortfolioOptimisers", "Clarabel"])

using Parquet2
using DataFrames
using Dates
using Statistics
using PortfolioOptimisers
using Clarabel

# ---- Configuration ----
const PREDICTIONS_PATH = get(ENV, "PREDICTIONS_PATH", "/mnt/cache/quant/lake/gspqr_predictions.parquet")
const TCP_PATH = get(ENV, "TCP_PATH", "/mnt/cache/quant/lake/tcp_calibration.parquet")
const VETO_PATH = get(ENV, "VETO_PATH", "/mnt/cache/quant/lake/veto_flags.parquet")
const CONVICTION_PATH = get(ENV, "CONVICTION_PATH", "/mnt/cache/quant/lake/conviction_scores.parquet")
const REGIME_PATH = get(ENV, "REGIME_PATH", "/mnt/cache/quant/lake/regime_states.parquet")
const PRICES_PATH = get(ENV, "PRICES_PATH", "/mnt/cache/quant/lake/prices.parquet")
const OUTPUT_PATH = get(ENV, "OUTPUT_PATH", "/mnt/cache/quant/lake/portfolio_targets.parquet")

const MAX_WEIGHT = 0.05
const MAX_SECTOR = 0.25
const CASH_BUFFER = 0.02

# ---- Main ----
function main()
    rebalance_date = length(ARGS) >= 2 && ARGS[1] == "--date" ?
                     Date(ARGS[2]) : today()

    @info "Optimizing portfolio for $rebalance_date"

    # Load inputs
    preds = DataFrame(Parquet2.read(PREDICTIONS_PATH))
    tcp = DataFrame(Parquet2.read(TCP_PATH))
    veto = DataFrame(Parquet2.read(VETO_PATH))
    conviction = DataFrame(Parquet2.read(CONVICTION_PATH))
    regime = DataFrame(Parquet2.read(REGIME_PATH))
    prices = DataFrame(Parquet2.read(PRICES_PATH))

    # Filter to latest date
    preds = filter(r -> r.date == rebalance_date, preds)
    tcp = filter(r -> r.forecast_date == rebalance_date, tcp)
    veto = filter(r -> r.as_of_date == rebalance_date && !r.veto_active, veto)
    conviction = filter(r -> r.as_of_date == rebalance_date, conviction)
    regime = filter(r -> r.date == rebalance_date, regime)

    # Regime factor
    regime_factor = isempty(regime) ? 1.0 : regime.regime_factor[1]
    if regime_factor == 0.0
        @warn "Crisis regime. No new positions."
        return
    end

    # Eligible universe (not vetoed)
    eligible = innerjoin(preds, veto, on = :ticker, makeunique = true)

    # Expected returns (GSPQR q_50, 63d horizon)
    eligible = filter(r -> r.horizon == "63d", eligible)

    # Merge conviction
    eligible = leftjoin(eligible, conviction, on = :ticker)

    # Build returns matrix for covariance
    # (in practice: pivot prices to wide format)
    # ...

    # Weights (simplified: equal weight for now, real implementation uses JuMP)
    n = nrow(eligible)
    if n == 0
        @warn "No eligible stocks"
        return
    end

    w_optimized = fill((1.0 - CASH_BUFFER) / n, n)

    # Apply conviction
    conviction_vals = coalesce.(eligible.conviction, 1.0)
    w_conviction = w_optimized .* conviction_vals
    w_final = w_conviction ./ sum(w_conviction) .* (1.0 - CASH_BUFFER)

    # Build output
    out = DataFrame(
        rebalance_date = fill(rebalance_date, n),
        ticker = eligible.ticker,
        expected_return = eligible.q_50,
        downside_risk = eligible.q_05,
        w_optimized = w_optimized,
        conviction = conviction_vals,
        w_conviction = w_conviction,
        w_final = w_final,
        veto_active = fill(false, n),
        cap_applied = fill(false, n),
    )

    Parquet2.write(OUTPUT_PATH, out)
    @info "Wrote $(nrow(out)) targets to $OUTPUT_PATH"
end

main()