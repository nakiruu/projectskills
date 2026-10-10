#!/usr/bin/env julia
# Fits GPD tails to calibrated residuals and writes evt_tail_bounds.parquet.
# Usage: julia fit-tails.jl [--fit-date 2026-10-10]

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "Statistics", "Distributions"])

using Parquet2
using DataFrames
using Dates
using Statistics
using Distributions

# ---- Configuration ----
const RESIDUALS_PATH = get(ENV, "RESIDUALS_PATH", "/mnt/cache/quant/lake/evt_residuals.parquet")
const OUTPUT_PATH    = get(ENV, "OUTPUT_PATH",    "/mnt/cache/quant/lake/evt_tail_bounds.parquet")

const THRESHOLD_Q = 0.95
const MIN_EXCEEDANCES = 50
const HORIZONS = ["63d", "126d", "252d"]

# ---- GPD fit ----
function fit_gpd(exceedances::Vector{Float64})
    n_u = length(exceedances)
    if n_u < MIN_EXCEEDANCES
        return nothing
    end

    try
        d = fit(GeneralizedPareto, exceedances; loc = 0.0)
        return (shape = d.ξ, scale = d.σ)
    catch e
        @warn "GPD fit failed: $e"
        return nothing
    end
end

# ---- Extreme quantile ----
function extreme_quantile(
    u::Float64, sigma::Float64, xi::Float64,
    n::Int, n_u::Int, p::Float64,
)::Float64
    if abs(xi) < 1e-6
        # Exponential case
        return u + sigma * log((n / n_u) * (1 - p))
    else
        return u + (sigma / xi) * ((n / n_u) * (1 - p))^(-xi) - 1
    end
end

# ---- Fit one tail ----
function fit_tail(
    residuals::Vector{Float64},
    tail::String,
)::Dict{String,Any}
    n = length(residuals)

    if tail == "upper"
        u = quantile(residuals, THRESHOLD_Q)
        exceedances = [r - u for r in residuals if r > u]
        p = 0.99
    else  # lower
        u = quantile(residuals, 1 - THRESHOLD_Q)
        exceedances = [u - r for r in residuals if r < u]
        p = 0.01
    end

    n_u = length(exceedances)

    if n_u < MIN_EXCEEDANCES
        @warn "Tail $tail: only $n_u exceedances, falling back to empirical"
        q_emp = tail == "upper" ? quantile(residuals, 0.99) : quantile(residuals, 0.01)
        return Dict(
            "threshold_u" => u,
            "n_exceedances" => n_u,
            "gpd_shape_xi" => NaN,
            "gpd_scale_sigma" => NaN,
            "q_extreme" => q_emp,
        )
    end

    gpd = fit_gpd(exceedances)
    if isnothing(gpd)
        q_emp = tail == "upper" ? quantile(residuals, 0.99) : quantile(residuals, 0.01)
        return Dict(
            "threshold_u" => u,
            "n_exceedances" => n_u,
            "gpd_shape_xi" => NaN,
            "gpd_scale_sigma" => NaN,
            "q_extreme" => q_emp,
        )
    end

    q_ext = extreme_quantile(u, gpd.scale, gpd.shape, n, n_u, p)

    if tail == "lower"
        q_ext = -q_ext  # convert back to residual scale
    end

    return Dict(
        "threshold_u" => u,
        "n_exceedances" => n_u,
        "gpd_shape_xi" => gpd.shape,
        "gpd_scale_sigma" => gpd.scale,
        "q_extreme" => q_ext,
    )
end

# ---- Main ----
function main()
    fit_date = length(ARGS) >= 2 && ARGS[1] == "--fit-date" ?
               Date(ARGS[2]) : today()

    @info "Fitting EVT tails for $fit_date"

    if !isfile(RESIDUALS_PATH)
        @error "Residuals not found: $RESIDUALS_PATH"
        return
    end

    residuals_df = DataFrame(Parquet2.read(RESIDUALS_PATH))

    results = Dict{String,Any}[]

    for (ticker, grp) in pairs(groupby(residuals_df, :ticker))
        for horizon in HORIZONS
            h_grp = filter(r -> r.horizon == horizon, grp)
            if nrow(h_grp) < 10
                continue
            end

            resids = collect(skipmissing(h_grp.residual))

            for tail in ["lower", "upper"]
                result = fit_tail(resids, tail)
                push!(results, merge(
                    Dict(
                        "ticker" => ticker,
                        "fit_date" => fit_date,
                        "horizon" => horizon,
                        "tail" => tail,
                    ),
                    result,
                ))
            end
        end
    end

    if isempty(results)
        @warn "No EVT results produced"
        return
    end

    out = DataFrame(results)
    Parquet2.write(OUTPUT_PATH, out)
    @info "Wrote $(nrow(out)) EVT rows to $OUTPUT_PATH"
end

main()