#!/usr/bin/env julia
# Fits the 3-state Gaussian HMM and writes regime_states.parquet.
# Usage: julia fit-regime.jl [--fit-date 2026-10-10]

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "Statistics", "Distributions",
         "HiddenMarkovModels"])

using Parquet2
using DataFrames
using Dates
using Statistics
using Distributions
using HiddenMarkovModels

# ---- Configuration ----
const PRICES_PATH = get(ENV, "PRICES_PATH", "/mnt/cache/quant/lake/prices.parquet")
const OUTPUT_PATH = get(ENV, "OUTPUT_PATH", "/mnt/cache/quant/lake/regime_states.parquet")

const N_STATES = 3
const TRAIN_WINDOW = 504
const CONFIRM_DAYS = 2

# ---- Fit HMM ----
function fit_regime_hmm(returns::Vector{Float64})
    # Initialize with KMeans-like split by quantiles
    q1 = quantile(returns, 1/3)
    q2 = quantile(returns, 2/3)

    # Simple initialization
    init_means = [mean(returns[returns .<= q1]),
                  mean(returns[(returns .> q1) .& (returns .<= q2)]),
                  mean(returns[returns .> q2])]

    init_vars = [var(returns[returns .<= q1]),
                 var(returns[(returns .> q1) .& (returns .<= q2)]),
                 var(returns[returns .> q2])]

    # Initialize transition matrix with high persistence
    trans = fill(0.05 / 2, N_STATES, N_STATES)
    for i in 1:N_STATES
        trans[i, i] = 0.95
    end

    init_probs = fill(1/N_STATES, N_STATES)

    # Create HMM
    emissions = [Normal(init_means[i], sqrt(init_vars[i])) for i in 1:N_STATES]

    hmm = HMM(initial_probs = init_probs,
              transition_matrix = trans,
              emissions = emissions)

    # Fit
    ll = fit!(hmm, returns; max_iter = 100, tol = 1e-6)

    return hmm, ll
end

# ---- Relabel by variance ----
function relabel_by_variance(hmm)
    variances = [hmm.emissions[i].σ^2 for i in 1:N_STATES]
    order = sortperm(variances)  # ascending: low_vol, high_vol, crisis
    return hmm, order
end

# ---- Confirm states ----
function confirmed_states(raw_states::Vector{Int})::Vector{Int}
    n = length(raw_states)
    confirmed = copy(raw_states)
    for t in 3:n
        if raw_states[t] == raw_states[t-1] == raw_states[t-2]
            confirmed[t] = raw_states[t]
        else
            confirmed[t] = confirmed[t-1]
        end
    end
    return confirmed
end

# ---- Regime factor ----
function regime_factor(state::Int)::Float64
    # After relabeling: 1 = low_vol, 2 = high_vol, 3 = crisis
    if state == 1
        return 1.0
    elseif state == 2
        return 0.5
    else
        return 0.0
    end
end

# ---- Main ----
function main()
    fit_date = length(ARGS) >= 2 && ARGS[1] == "--fit-date" ?
               Date(ARGS[2]) : today()

    @info "Fitting regime HMM for $fit_date"

    prices = DataFrame(Parquet2.read(PRICES_PATH))

    # Compute equal-weighted universe returns
    prices = sort(prices, [:date, :ticker])
    prices.ret = [NaN; diff(log.(prices.close))]

    # Aggregate to daily universe return
    daily = combine(groupby(prices, :date),
                    :ret => (x -> mean(skipmissing(x))) => :univ_ret)
    daily = sort(daily, :date)
    daily = filter(r -> !ismissing(r.univ_ret), daily)

    # Take trailing window
    if nrow(daily) < TRAIN_WINDOW
        @error "Insufficient data: $(nrow(daily)) < $TRAIN_WINDOW"
        return
    end

    window = daily[(end - TRAIN_WINDOW + 1):end, :]
    returns = collect(window.univ_ret)

    # Fit
    hmm, ll = fit_regime_hmm(returns)
    @info "HMM fit complete. Final log-likelihood: $(ll[end])"

    # Relabel by variance
    hmm, order = relabel_by_variance(hmm)

    # Decode
    raw_states = viterbi(hmm, returns)
    probs = forward_backward(hmm, returns)

    # Confirm
    confirmed = confirmed_states(raw_states)

    # Build output
    state_labels = ["low_vol", "high_vol", "crisis"]

    out = DataFrame(
        date = window.date,
        regime_low_vol_prob = probs[1, :],
        regime_high_vol_prob = probs[2, :],
        regime_crisis_prob = probs[3, :],
        viterbi_state = [state_labels[s] for s in raw_states],
        regime_factor = [regime_factor(s) for s in confirmed],
    )

    Parquet2.write(OUTPUT_PATH, out)
    @info "Wrote $(nrow(out)) regime rows to $OUTPUT_PATH"
end

main()