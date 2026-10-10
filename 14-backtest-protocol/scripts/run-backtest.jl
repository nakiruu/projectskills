#!/usr/bin/env julia
# Runs CPCV backtest and writes evaluation_metrics.parquet.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "Statistics", "DataSplits"])

using Parquet2
using DataFrames
using Dates
using Statistics
using DataSplits

# ---- Configuration ----
const PANEL_PATH = get(ENV, "PANEL_PATH", "/mnt/cache/quant/lake/panel.parquet")
const OUTPUT_PATH = get(ENV, "OUTPUT_PATH", "/mnt/cache/quant/lake/evaluation_metrics.parquet")

const N_GROUPS = 10
const K_TEST = 8
const PURGE_DAYS = 21
const EMBARGO_DAYS = 21

# ---- CPCV splitting (using DataSplits.jl PurgedKFold) ----
function build_cpcv_folds(panel::DataFrame)
    # In production: use DataSplits.PurgedKFold with purge and embargo
    # This is a simplified skeleton
    dates = sort(unique(panel.date))
    n = length(dates)
    group_size = div(n, N_GROUPS)

    groups = [dates[(i-1)*group_size + 1 : min(i*group_size, n)] for i in 1:N_GROUPS]

    folds = []
    # Generate combinations of K_TEST test groups
    # (in practice: use CombinatorialCrossValidation from DataSplits.jl)
    push!(folds, (train_dates = dates[1:group_size*2], test_dates = dates[group_size*2+1:end]))
    return folds
end

# ---- Coverage ----
function coverage(y::Vector{Float64}, lower::Vector{Float64}, upper::Vector{Float64})::Float64
    return mean((y .>= lower) .& (y .<= upper))
end

# ---- Winkler Score ----
function winkler(y::Vector{Float64}, lower::Vector{Float64}, upper::Vector{Float64}, alpha::Float64)::Float64
    n = length(y)
    total = 0.0
    for i in 1:n
        width = upper[i] - lower[i]
        if y[i] < lower[i]
            total += width + (2/alpha) * (lower[i] - y[i])
        elseif y[i] > upper[i]
            total += width + (2/alpha) * (y[i] - upper[i])
        else
            total += width
        end
    end
    return total / n
end

# ---- Pinball Loss ----
function pinball(y::Vector{Float64}, yhat::Vector{Float64}, tau::Float64)::Float64
    n = length(y)
    total = 0.0
    for i in 1:n
        d = y[i] - yhat[i]
        total += d >= 0 ? tau * d : (1 - tau) * (-d)
    end
    return total / n
end

# ---- Sortino Ratio ----
function sortino(returns::Vector{Float64}, target::Float64)::Float64
    excess = returns .- target
    downside = excess[excess .< 0]
    if isempty(downside)
        return Inf
    end
    dd = sqrt(mean(downside .^ 2))
    return mean(excess) / dd
end

# ---- Main ----
function main()
    @info "Running CPCV backtest"

    panel = DataFrame(Parquet2.read(PANEL_PATH))
    folds = build_cpcv_folds(panel)

    all_metrics = []

    for (fold_idx, fold) in enumerate(folds)
        @info "Fold $fold_idx / $(length(folds))"

        train = filter(r -> r.date in fold.train_dates, panel)
        test = filter(r -> r.date in fold.test_dates, panel)

        # In production:
        # 1. Train GSPQR on train
        # 2. Calibrate TCP on train
        # 3. Fit EVT on train residuals
        # 4. Predict on test
        # 5. Run optimizer on test
        # 6. Apply lock gating
        # 7. Compute returns

        # Simplified: use existing predictions
        y = collect(skipmissing(test.y_fwd_63d))
        lower = test.q_hat_lower[1:length(y)]
        upper = test.q_hat_upper[1:length(y)]

        if isempty(y)
            continue
        end

        metrics = Dict(
            "fold" => fold_idx,
            "coverage_95" => coverage(y, lower, upper),
            "winkler_score" => winkler(y, lower, upper, 0.05),
            "pinball_loss" => mean([
                pinball(y, lower, 0.05),
                pinball(y, (lower .+ upper) ./ 2, 0.50),
                pinball(y, upper, 0.95),
            ]),
            "n_obs" => length(y),
        )
        push!(all_metrics, metrics)
    end

    if isempty(all_metrics)
        @warn "No backtest results"
        return
    end

    out = DataFrame(all_metrics)
    Parquet2.write(OUTPUT_PATH, out)
    @info "Wrote $(nrow(out)) metric rows to $OUTPUT_PATH"

    # Report distribution
    @info "Coverage: mean=$(mean(out.coverage_95)), std=$(std(out.coverage_95))"
    @info "Winkler: mean=$(mean(out.winkler_score)), std=$(std(out.winkler_score))"
end

main()