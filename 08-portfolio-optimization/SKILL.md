---
name: portfolio-optimization
description: Post-Modern Portfolio Theory (PMPT) portfolio construction.
  Load when touching portfolio/, JuMP optimization, Sortino ratio, or
  weight constraints.
---

# Portfolio Optimization

The portfolio layer takes the prediction engine's outputs and produces
target weights. It uses Post-Modern Portfolio Theory (PMPT), which
minimizes downside risk rather than total variance.

## 1. Why PMPT Over MPT

Modern Portfolio Theory (MPT) defines risk as the variance of returns.
This penalizes upside volatility equally with downside losses. Research
in behavioral finance (Kahneman and Tversky 1979) demonstrates that
investors are loss-averse: the psychological disutility of a loss is
roughly twice the utility of an equivalent gain.

Post-Modern Portfolio Theory (PMPT) replaces variance with **downside
deviation** (Lower Partial Moment). It measures risk only from returns
below a target, aligning the optimization with the actual utility
function of a loss-averse investor.

Empirical results from a 2025 study on US equities (2008–2024):

| Metric | MPT (Min Variance) | PMPT (Min Semivariance) |
|---|---|---|
| Max Drawdown (large-cap) | −39.62% | −23.72% |
| Sortino Ratio (skewed assets) | 0.96 | 1.30 |
| CAGR (skewed assets) | — | 11.48% |

The PMPT portfolio reduced maximum drawdown by approximately 16
percentage points compared to MPT in the large-cap universe. A
separate simulation-based study found PMPT achieved a higher Sortino
ratio (1.60) and lower maximum drawdown (0.14) than MPT.

## 2. Inputs

| Input | Source | Purpose |
|---|---|---|
| Expected returns | GSPQR `q_50` | Optimization objective |
| Downside risk | GSPQR `q_05` lower semi-deviation | Risk measure |
| Covariance | Ledoit-Wolf shrinkage | For risk contribution |
| Regime factor | `regime_states.parquet` | Pre-optimization gate |
| Veto flags | `veto_flags.parquet` | Pre-optimization filter |
| Conviction | `conviction_scores.parquet` | Post-optimization scale |

## 3. The Optimization Problem

Minimize portfolio downside deviation subject to:

- **Fully invested:** `Σ w_i = 1.0`
- **Long-only:** `w_i ≥ 0`
- **Position cap:** `w_i ≤ 0.05` (5% single-name)
- **Sector cap:** `Σ_{i ∈ sector} w_i ≤ 0.25` (25% per GICS sector)
- **Cash buffer:** `Σ w_i ≤ 0.98` (2% minimum cash)

The objective is the Sortino ratio maximization, formulated as a
Second-Order Cone Program (SOCP) for guaranteed global optimality.
See `PMPT-FORMULATION.md` for the exact formulation.

## 4. Application Order

```
GSPQR q_50 → VETO FILTER → Optimizer → CONVICTION SCALE → Lock Gate → Execution
```

**Veto before optimizer.** Vetoed stocks are removed from the eligible
universe. The optimizer never sees them.

**Conviction after optimizer.** The optimizer produces weights subject
to the 5% cap and 25% sector cap. Conviction then scales each weight:

    w_conviction = w_optimized × conviction

Then renormalize to sum to 1 (or 0.98 with cash buffer). See §5.

## 5. Conviction Application

Conviction scales weights **after** the optimizer has enforced
constraints. This ordering matters: if conviction were applied before,
a high-conviction stock could push past the 5% cap after renormalization.

```julia
# After optimizer produces w_optimized
w_conviction = w_optimized .* conviction

# Renormalize to sum to (1 - cash_buffer)
target_sum = 0.98
w_final = w_conviction ./ sum(w_conviction) .* target_sum

# Apply caps iteratively
w_final = apply_caps(w_final; max_weight = 0.05, max_sector = 0.25)
```

The cap application is iterative: if a weight hits the 5% cap, the
excess is redistributed proportionally to uncapped positions. Repeat
until convergence (typically 2–3 passes).

## 6. Constraint Implementation

Using `PortfolioOptimisers.jl` with JuMP and Clarabel:

```julia
using PortfolioOptimisers, Clarabel

# Weight bounds: 0 ≤ w_i ≤ 0.05
wb = WeightBounds(; lb = 0.0, ub = 0.05)

# Sector caps: 25% max per sector
sector_constraints = LinearConstraintEstimator(
    "tech <= 0.25",
    "financials <= 0.25",
    "energy <= 0.25",
    # ... all GICS sectors
)

# Cash buffer: sum of weights ≤ 0.98
cash_constraint = LinearConstraintEstimator("sum <= 0.98")

# Solver
slv = Solver(; name = :clarabel, solver = Clarabel.Optimizer)
```

The `PortfolioOptimisers.jl` package supports weight bounds, linear
group constraints, and sector bands as `JuMPOptimiser` keywords.

### 6a. Fractional-Share Constraint

The optimizer produces **weights**, not share quantities. The conversion
from weights to quantities happens in the Rust order generator, not here.
The optimizer is unaware of the execution tier.

The order generator handles the three tiers as follows:

| Tier | Conversion |
|---|---|
| Bootstrap | `quantity = weight × NAV / price`, fractional, submitted as a market order |
| Transition | `whole = floor(weight × NAV / price)`, submitted as a limit; `remainder = weight × NAV / price - whole`, submitted as a market order if `remainder > 0` |
| Standard | `quantity = round(weight × NAV / price)`, rounded to whole shares, submitted as a limit; residual to cash |

The optimizer's weights are the same in all three tiers. The tier affects
only the order generator's rounding. A weight of 0.03 for a $200 stock
with $2,000 NAV produces:

- Bootstrap: 0.30 shares, market order
- Transition: 0 whole shares, 0.30 fractional market order
- Standard: 0 whole shares, no order, residual to cash

The Standard tier cannot hold this position at this NAV. This is
expected. The 5% cap means a $2,000 account can hold at most 0.50 shares
of a $200 stock, which is below the whole-share minimum. Small NAV
accounts are structurally constrained to whole-share positions, which is
why the Bootstrap and Transition tiers exist.

### 6b. Interaction With the Cash Buffer

The 2% cash buffer is enforced at the weight level, before quantity
conversion. The optimizer produces weights summing to at most 0.98. The
order generator converts these to quantities and rounds. The rounding
residual (from whole-share rounding) returns to cash, so the actual cash
after execution is at least the buffer.

In the Bootstrap and Transition tiers, fractional quantities mean the
rounding residual is small. The cash buffer is approximately the target.
In the Standard tier, whole-share rounding can leave several percent in
cash for small positions. This is acceptable; the buffer is a minimum,
not a target.

## 7. What Not to Do

- Do not use variance as the risk measure. Use downside deviation.
- Do not apply conviction before the optimizer. Constraints would be
  violated after renormalization.
- Do not skip the cash buffer. 2% minimum cash is a constitution
  requirement (§6).
- Do not use a sample covariance matrix. Use Ledoit-Wolf shrinkage
  (see `COVARIANCE.md`).
- Do not allow the optimizer to produce weights above 5% for any name.
  The cap is a hard constraint.
- Do not ignore sector caps. 25% per GICS sector is a hard constraint.
- Do not convert weights to share quantities in Julia. The conversion
  happens in the Rust order generator, which knows the execution tier.
- Do not assume whole-share quantities in the Bootstrap or Transition
  tiers. Positions are fractional.

## 8. Verification

- [ ] A test asserts weights sum to ≤ 0.98 (cash buffer)
- [ ] A test asserts no weight exceeds 0.05
- [ ] A test asserts no sector exceeds 0.25
- [ ] A test asserts all weights are ≥ 0 (long-only)
- [ ] A test asserts vetoed stocks receive weight 0.0
- [ ] A test asserts conviction is applied after optimization
- [ ] A test asserts the SOCP solver converges (no fallback to heuristic)
- [ ] A test asserts the optimizer output is weights, not quantities

## 9. Related Skills

- `03-gspqr-model` — provides `q_50` (expected return) and `q_05` (downside)
- `06-regime-detection` — provides `regime_factor`
- `07-fundamental-overlay` — provides veto and conviction
- `09-lock-state-machine` — gates execution after optimization
- `10-execution-schwab` — the order generator that converts weights to quantities
- `00-constitution` §6, §6a — position, sector, cash constraints and NAV tiers
