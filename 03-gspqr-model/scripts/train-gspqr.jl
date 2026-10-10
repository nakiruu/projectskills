#!/usr/bin/env julia
# Trains all 21 GSPQR models and updates the registry.
# Usage: julia train-gspqr.jl [--generation 2026-10-01]

using Pkg
Pkg.activate(temp=true)
Pkg.add([
    "Parquet2", "DataFrames", "Dates", "JSON3",
    "LightGBM", "Statistics", "Printf",
])

using Parquet2
using DataFrames
using Dates
using JSON3
using LightGBM
using Statistics
using Printf

# ---- Configuration ----
const PANEL_PATH    = get(ENV, "PANEL_PATH",    "/mnt/cache/quant/lake/panel.parquet")
const MODELS_DIR    = get(ENV, "MODELS_DIR",    "/mnt/cache/quant/models")
const REGISTRY_PATH = get(ENV, "REGISTRY_PATH", "/mnt/cache/quant/models/registry.json")

const FEATURES = [
    :mom_20d, :mom_60d, :mom_12m_1m,
    :vol_60d_res, :sp_ratio, :turn_20d,
    :r_mom_20d, :r_mom_60d, :r_mom_12m_1m,
    :r_vol_60d, :r_sp, :r_turn,
]

const HORIZONS = [("63d", :y_fwd_63d), ("126d", :y_fwd_126d), ("252d", :y_fwd_252d)]
const QUANTILES = [0.01, 0.05, 0.25, 0.50, 0.75, 0.95, 0.99]

# ---- Hyperparameters ----
function params_for(tau::Float64)
    base = Dict{String,Any}(
        "objective"        => "quantile",
        "alpha"            => tau,
        "metric"           => "quantile",
        "boosting"         => "gbdt",
        "num_leaves"       => 31,
        "learning_rate"    => 0.05,
        "min_data_in_leaf" => 100,
        "feature_fraction" => 0.8,
        "bagging_fraction" => 0.8,
        "bagging_freq"     => 5,
        "lambda_l1"        => 0.1,
        "lambda_l2"        => 0.1,
        "max_bin"          => 255,
        "use_missing"      => true,
        "zero_as_missing"  => false,
        "verbose"          => -1,
        "seed"             => 42,
        "num_threads"      => -1,
        "deterministic"    => true,
    )
    n_estimators = 500
    if tau in (0.01, 0.99)
        base["min_data_in_leaf"] = 200
        n_estimators = 800
    elseif tau in (0.25, 0.75)
        n_estimators = 400
    end
    return base, n_estimators
end

# ---- Pinball Loss ----
function pinball(y::Vector{Float64}, yhat::Vector{Float64}, tau::Float64)
    n = length(y)
    s = 0.0
    for i in 1:n
        d = y[i] - yhat[i]
        s += d >= 0 ? tau * d : (1 - tau) * (-d)
    end
    return s / n
end

# ---- Main ----
function main()
    generation = length(ARGS) >= 2 && ARGS[1] == "--generation" ?
                 ARGS[2] : string(today())

    @info "Training GSPQR generation $generation"

    if !isfile(PANEL_PATH)
        error("Panel not found: $PANEL_PATH")
    end

    panel = DataFrame(Parquet2.read(PANEL_PATH))
    @info "Loaded panel: $(nrow(panel)) rows, $(length(unique(panel.ticker))) tickers"

    train_panel = filter(r -> r.split == "train", panel)
    @info "Train rows: $(nrow(train_panel))"

    # Determine validation boundary (80th percentile of train dates)
    train_dates = sort(unique(train_panel.date))
    val_idx = floor(Int, 0.8 * length(train_dates))
    val_boundary = train_dates[val_idx]
    @info "Validation boundary: $val_boundary"

    registry = Dict{String,Any}(
        "generation" => generation,
        "trained_at" => string(now(UTC)),
        "panel_version" => string(maximum(panel.date)),
        "train_rows" => nrow(train_panel),
        "train_tickers" => length(unique(train_panel.ticker)),
        "models" => Dict{String,Any}(),
    )

    mkpath(MODELS_DIR)

    for (horizon_label, target_col) in HORIZONS
        @info "Horizon $horizon_label"

        # Filter to non-NaN targets for this horizon