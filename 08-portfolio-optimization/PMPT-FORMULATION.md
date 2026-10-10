# PMPT Formulation

The Post-Modern Portfolio Theory optimization problem, formulated as a
Second-Order Cone Program (SOCP).

## 1. The Objective

Maximize the Sortino ratio:

    Sortino = (E[R_p] − R_target) / σ_downside

Where:
- `E[R_p]` = expected portfolio return (from GSPQR `q_50`)
- `R_target` = minimum acceptable return (MAR), typically the risk-free rate
- `σ_downside` = downside deviation (lower semi-deviation)

## 2. Downside Deviation

The downside deviation is the square root of the lower partial moment:

    σ_downside = sqrt( (1/T) × Σ_t max(0, R_target − R_{p,t})² )

Where `R_{p,t}` is the portfolio return at time `t`.

Unlike variance, which penalizes all deviations from the mean, the
downside deviation penalizes only returns below the target. This is the
key difference between MPT and PMPT .

## 3. SOCP Formulation

The Sortino maximization can be reformulated as a linear objective with
a second-order cone constraint :

    min  t
    s.t. Σ_i w_i × μ_i − R_target ≥ 0
         ||d||_2 ≤ t
         d_t ≥ max(0, R_target − Σ_i w_i × r_{i,t})  for all t
         Σ_i w_i ≤ 0.98
         0 ≤ w_i ≤ 0.05
         Σ_{i ∈ sector s} w_i ≤ 0.25  for all s

Where:
- `w_i` = weight of asset `i`
- `μ_i` = expected return of asset `i` (GSPQR `q_50`)
- `r_{i,t}` = historical return of asset `i` at time `t`
- `d_t` = downside deviation at time `t`
- `t` = auxiliary variable (the downside deviation to minimize)

The `||d||_2 ≤ t` constraint is a second-order cone. This is what makes
the problem a SOCP, solvable to global optimality by Clarabel
.

## 4. Why SOCP Over Heuristic

Earlier downside-risk literature used heuristic approximations because
the problem was computationally complex . Modern convex
optimization solves the Global Minimum Semivariance problem exactly.
The 2025 study explicitly uses SOCP to "ensure convergence to true
global minima without heuristic approximation" .

The pipeline uses `PortfolioOptimisers.jl` with Clarabel, which
supports SOCP constraints natively .

## 5. The Target Return

The minimum acceptable return (MAR) is set to the daily risk-free rate
(from FRED `DGS3MO`), converted to the rebalance horizon:

    R_target = (1 + DGS3MO/100)^(H/252) − 1

For a monthly rebalance (H = 21), this is approximately the 1-month
T-bill rate.

## 6. Expected Returns

The expected returns `μ_i` come from the GSPQR `q_50` (median) forecast
for the rebalance horizon. These are **not** historical mean returns.
They are forward-looking quantile estimates from the LightGBM model.

Using GSPQR `q_50` rather than historical mean is critical. Historical
means are notoriously noisy and unstable . The GSPQR
median is a regularized, feature-conditioned estimate.

## 7. Covariance Matrix

The covariance matrix for the risk model is estimated via Ledoit-Wolf
shrinkage. See `COVARIANCE.md`. The covariance is used for the
risk-contribution constraints (sector caps are implemented via
exposure constraints), not for the objective (which uses downside
deviation).

## 8. What Not to Do

- Do not use variance as the risk measure. The objective uses downside
  deviation.
- Do not use historical mean returns as `μ_i`. Use GSPQR `q_50`.
- Do not use a heuristic approximation. The SOCP solves to global
  optimality.
- Do not set `R_target` to 0. Use the risk-free rate.
- Do not skip the SOCP formulation and use a QP solver. The downside
  deviation constraint is not quadratic; it is a cone.