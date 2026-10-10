#!/usr/bin/env julia
# Runs TCP calibration for a given forecast date.
# Usage: julia calibrate.jl [--forecast-date 2026-10-10]

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "Statistics"])

using Parquet2
using DataFrames
using Dates
using Statistics

# ---- Configuration ----
const GSPQR_PATH = get(ENV, "GSPQR_PATH", "/mnt/cache/quant/lake/gspqr_predictions.parquet")
const PRICES_PATH = get(ENV, "PRICES_PATH", "/mnt/cache/quant/lake/prices.parquet")
const OUTPUT_PATH = get(ENV, "OUTPUT_PATH", "/mnt/cache/quant/lake/tcp_calibration.parquet")

const M_CAL = 60
const ALPHA = 0.05
const GAMMA_0 = 0.01
const OFFSET_CLIP = (-0.5, 0.5)

const HORIZONS = ["63d", "126d", "252d"]

# ---- Zero-truncated conformity score ----
function conformity_score(q05::Float64, q95::Float64, y::Float64)::Float64
    return max(q05 - y, y - q95, 0.0)
end

# ---- Order statistic ----
function conformal_quantile(scores::Vector{Float64}, alpha::Float64)::Float64
    m = length(scores)
    if m == 0
        return 0.0
    end
    k = ceil(Int, (m + 1) * (1 - alpha))
    sorted = sort(scores)
    return k <= m ? sorted[k] : sorted[end]
end

# ---- Robbins-Monro update ----
function rm_update(c_t::Float64, e_t::Float64, t::Int, gamma_0::Float64)::Float64
    gamma_t = gamma_0 / sqrt(t + 1)
    c_next = c_t + gamma_t * e_t
    return clamp(c_next, OFFSET_CLIP[1], OFFSET_CLIP[2])
end

# ---- Main calibration for one ticker, horizon, date ----
function calibrate_one(
    gspqr::DataFrame,
    prices::DataFrame,
    ticker::String,
    horizon::String,
    forecast_date::Date,
)::Union{Dict{String,Any},Nothing}

    # Calibration window: [t-m, t-1]
    window_start = forecast_date - Day(M_CAL)
    window_end = forecast_date - Day(1)

    # Filter GSPQR predictions to the window
    cal = filter(
        r -> r.ticker == ticker &&
             r.horizon == horizon &&
             window_start <= r.date <= window_end,
        gspqr,
    )

    if nrow(cal) == 0
        return nothing
    end

    # Compute conformity scores
    scores = Float64[]
    for row in eachrow(cal)
        # Find realized return for this date and horizon
        # (simplified; in practice, join to prices and compute forward return)
        y = get_realized_return(prices, ticker, row.date, horizon)
        if isnothing(y)
            continue
        end
        push!(scores, conformity_score(row.q_05, row.q_95, y))
    end

    if length(scores) < 10
        return nothing  # insufficient calibration data
    end

    # Conformal quantile
    q_hat = conformal_quantile(scores, ALPHA)

    # Robbins-Monro offset (simplified; in practice, read/write state)
    # c_t = get_current_offset(ticker, horizon)
    # q_hat += c_t

    # Get raw quantiles for the forecast date
    forecast_row = filter(
        r -> r.ticker == ticker &&
             r.horizon == horizon &&
             r.date == forecast_date,
        gspqr,
    )

    if nrow(forecast_row) == 0
        return nothing
    end

    q05 = forecast_row.q_05[1]
    q95 = forecast_row.q_95[1]

    return Dict(
        "ticker" => ticker,
        "forecast_date" => forecast_date,
        "horizon" => horizon,
        "alpha" => ALPHA,
        "m_cal" => M_CAL,
        "k_order_stat" => ceil(Int, (M_CAL + 1) * (1 - ALPHA)),
        "q_hat_lower" => q05 - q_hat,
        "q_hat_upper" => q95 + q_hat,
        "rm_offset" => 0.0,  # placeholder
        "calib_width" => (q95 + q_hat) - (q05 - q_hat),
    )
end

# Placeholder for realized return lookup
function get_realized_return(prices::DataFrame, ticker::String, date::Date, horizon::String)
    # In practice: compute forward return from date to date+H
    # Returns NaN if the forward window extends beyond available data
    return nothing
end

function main()
    forecast_date = length(ARGS) >= 2 && ARGS[1] == "--forecast-date" ?
                    Date(ARGS[2]) : today()

    @info "Running TCP calibration for $forecast_date"

    gspqr = DataFrame(Parquet2.read(GSPQR_PATH))
    prices = DataFrame(Parquet2.read(PRICES_PATH))

    tickers = unique(gspqr.ticker)
    results = Dict{String,Any}[]

    for ticker in tickers
        for horizon in HORIZONS
            row = calibrate_one(gspqr, prices, ticker, horizon, forecast_date)
            if !isnothing(row)
                push!(results, row)
            end
        end
    end

    if isempty(results)
        @warn "No calibration results produced"
        return
    end

    out = DataFrame(results)
    # Append to output (atomic write in production)
    Parquet2.write(OUTPUT_PATH, out)
    @info "Wrote $(nrow(out)) calibration rows to $OUTPUT_PATH"
end

main()