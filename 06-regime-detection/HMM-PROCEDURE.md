# HMM Procedure

The step-by-step algorithm for fitting the Gaussian HMM and decoding
regimes.

## 1. Inputs

For a given fit date `t`:

- Daily log returns of the equal-weighted universe for the trailing
  504 trading days.
- The previous fit's parameters (for warm-start, optional).

## 2. Fitting

```julia
using HiddenMarkovModels
using Distributions

function fit_regime_hmm(returns::Vector{Float64})::HMM
    # Initialize with KMeans on the returns
    # (or warm-start from previous fit)
    init = kmeans_init(returns, 3)

    # Fit via Baum-Welch (EM)
    hmm = HMM(
        initial_probs = init.probs,
        transition_matrix = init.trans,
        emissions = [Normal(init.μ[i], init.σ[i]) for i in 1:3],
    )

    fit!(hmm, returns; max_iter = 100, tol = 1e-6)

    return hmm
end
```

**Initialization:** KMeans on the returns is the default .
For a refit, warm-start from the previous parameters if the previous
fit converged. Warm-start speeds convergence and reduces label-switching
risk.

**Convergence:** EM stops when the log-likelihood improves by less
than `1e-6` or after 100 iterations. The log-likelihood must be
monotonically non-decreasing. If it decreases, the fit is invalid.

## 3. Decoding

Two outputs per date:

**Viterbi path** (most likely state sequence):

```julia
states = viterbi(hmm, returns)
```

**Forward-backward probabilities** (marginal state probabilities):

```julia
probs = forward_backward(hmm, returns)
```

The Viterbi path is used for the `viterbi_state` column. The
forward-backward probabilities are used for the `regime_*_prob` columns.

**Viterbi vs. PMAP:** Viterbi maximizes the joint probability of the
state sequence. It produces fewer transitions (more conservative) and
is more sensitive to model specification. PMAP maximizes the marginal
probability at each time step and can produce inadmissible transitions
[4]. The pipeline uses Viterbi for the decoded state and
forward-backward for the probabilities. This is the standard practice
.

## 4. State Analysis

After fit, compute per-state statistics on the training window:

| Statistic | Computation |
|---|---|
| Mean return | `mean(returns[state == i])` |
| Variance | `var(returns[state == i])` |
| Annualized volatility | `sqrt(variance × 252)` |
| Occupancy | `count(state == i) / length(returns)` |
| Persistence | Diagonal of transition matrix |

These are diagnostic. They confirm the states are economically distinct
and that the labels are sensible.

## 5. Relabeling

After the fit, relabel states by emission variance:

```julia
function relabel_by_variance(hmm::HMM)::HMM
    variances = [hmm.emissions[i].σ^2 for i in 1:3]
    order = sortperm(variances)  # ascending
    # Reorder states to match low_vol, high_vol, crisis
    # (permute initial_probs, transition_matrix, emissions)
    ...
end
```

**Why this matters:** EM can converge with the states in any order.
Without relabeling, `state 1` might be `crisis` in one fit and
`low_vol` in the next. The `regime_factor` mapping would silently
invert. Relabeling by variance prevents this.

## 6. The Confirmation Rule

The raw Viterbi state is stored. The confirmed state is computed by
scanning backward:

```julia
function confirmed_states(raw_states::Vector{Int})::Vector{Int}
    n = length(raw_states)
    confirmed = copy(raw_states)
    for t in 3:n
        # Only confirm if the current state has been stable for 2 days
        if raw_states[t] == raw_states[t-1] == raw_states[t-2]
            confirmed[t] = raw_states[t]
        else
            confirmed[t] = confirmed[t-1]
        end
    end
    return confirmed
end
```

The confirmed state drives `regime_factor`. The raw state drives
`viterbi_state` (for analysis).

## 7. Warm-Start and Refit

On monthly refit:

1. Load the previous fit's parameters.
2. Run KMeans on the new window (as a baseline).
3. Fit EM with the new KMeans init.
4. Fit EM with the previous parameters as init.
5. Choose the fit with the higher log-likelihood.
6. Relabel by variance.
7. Compare to the previous fit's state occupancy. If the occupancy
   shifted by more than 30%, log a `WARN` (possible structural shift).

## 8. What Not to Do

- Do not skip the relabeling step. It is the most common source of
   silent regime inversion.
- Do not use a single day's Viterbi state for the regime factor.
- Do not fit on the full history and evaluate in-sample.
- Do not use more than 3 states.
- Do not assume the HMM captures direction. It captures volatility.
- Do not ignore a decreasing log-likelihood. It indicates a bad fit.

## 9. Verification

- [ ] A test with synthetic 3-state data recovers the state sequence
- [ ] A test asserts states are relabeled by variance
- [ ] A test asserts the 2-day confirmation rule
- [ ] A test asserts the log-likelihood is non-decreasing
- [ ] A test asserts the transition matrix rows sum to 1
- [ ] A test asserts the forward-backward probabilities sum to 1 per date