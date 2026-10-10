---
name: regime-detection
description: Gaussian HMM regime detection for the portfolio gate. Load
  when touching regime/, HMM fitting, Viterbi decoding, or regime factors.
---

# Regime Detection

The regime gate answers one question: is the market currently in a
state where the model's predictions should be trusted at full size, at
half size, or not at all? It does not predict returns. It classifies
the current volatility environment.

## 1. What the Regime Gate Produces

For each trading date, one row in `regime_states.parquet`:

| Output | Meaning |
|---|---|
| `regime_low_vol_prob` | P(low volatility regime) |
| `regime_high_vol_prob` | P(high volatility regime) |
| `regime_crisis_prob` | P(crisis regime) |
| `viterbi_state` | Decoded state (low_vol / high_vol / crisis) |
| `regime_factor` | Multiplier applied to position sizes (1.0 / 0.5 / 0.0) |

The `regime_factor` is what the portfolio layer consumes. See §5.

## 2. Why a Regime Gate

GSPQR produces calibrated intervals. Those intervals are valid
**conditional on the training distribution**. When the market shifts
regime, the training distribution no longer describes the current
environment, and the intervals become unreliable until the model
adapts.

The regime gate is a blunt instrument for this problem. It does not
fix the model. It reduces exposure when the model's assumptions are
most likely to be violated. Three regimes are enough to capture the
distinction that matters: calm, turbulent, and crisis.

## 3. Model Specification

**3-state Gaussian HMM** fit to daily log returns of the equal-weighted
universe.

| Component | Specification |
|---|---|
| States | 3 |
| Emissions | Gaussian, full covariance |
| Features | Daily log returns (single feature) |
| Training window | Expanding or rolling 504 days (2 years) |
| Decoding | Viterbi for the state; forward-backward for probabilities |

The three states are labeled post-fit by their volatility:

| State | Label | Typical volatility |
|---|---|---|
| Lowest variance | `low_vol` | ~10-15% annualized |
| Middle variance | `high_vol` | ~20-30% annualized |
| Highest variance | `crisis` | ~40%+ annualized |

**Label switching:** The EM algorithm can converge with states swapped.
The fit procedure relabels states by their emission variance after
convergence. See `HMM-PROCEDURE.md` §5.

## 4. Confirmation Rule

A single day's Viterbi state does not trigger a regime change. The
system requires **2 consecutive days** in the new state before the
`regime_factor` updates.

**Why:** HMM state transitions flicker. A single bad day can flip the
Viterbi path without indicating a real regime change. The confirmation
rule trades a one-day lag for a large reduction in false transitions.
Research on regime-switching strategies notes that excessive regime
shifts increase transaction costs, and controlling false alarms is a
practical concern [citation:1].

The `regime_states.parquet` stores the raw Viterbi state. The
`regime_factor` column stores the confirmed state after the 2-day rule.

## 5. Regime Factor Mapping

| Confirmed state | `regime_factor` | Effect on sizing |
|---|---|---|
| `low_vol` | 1.0 | Full size |
| `high_vol` | 0.5 | Half size |
| `crisis` | 0.0 | No new positions |

The factor multiplies the portfolio optimizer's target weights **before**
conviction scaling. A crisis regime means the optimizer's output is
discarded for new entries; existing positions are not force-exited
(that is the lock's domain), but no new capital is deployed.

## 6. What Not to Do

- Do not use more than 3 states. The economic labels become
  ambiguous beyond three, and the model overfits.
- Do not use a single day's Viterbi state. Apply the 2-day
  confirmation rule.
- Do not label states by their index. Label by emission variance
  after fit. See `HMM-PROCEDURE.md` §5.
- Do not fit the HMM on the full history and evaluate in-sample.
  Use a rolling or expanding window. See `HMM-PROCEDURE.md` §2.
- Do not assume the HMM captures directional regimes. It captures
  volatility regimes. A `high_vol` state can occur in a bull or bear
  market [citation:12].
- Do not use the regime gate as a return predictor. It is a risk gate.

## 7. Verification

Before deploying a regime change:

- [ ] A test asserts 3 states with distinct variances after fit
- [ ] A test asserts state relabeling by variance
- [ ] A test asserts the 2-day confirmation rule
- [ ] A test asserts `regime_factor` mapping (1.0 / 0.5 / 0.0)
- [ ] `regime_states.parquet` schema matches the registry
- [ ] The HMM's log-likelihood is monotonically increasing during EM

## 8. Related Skills

- `08-portfolio-optimization` — consumes `regime_factor`
- `11-rust-event-bus` — `RegimeFlip` event is emitted on confirmed changes
- `13-parquet-lake` — schema for `regime_states.parquet`
- `14-backtest-protocol` — evaluates coverage per regime