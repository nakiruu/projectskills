#!/usr/bin/env julia
# Computes veto flags and conviction scores for all eligible stocks.
# Writes veto_flags.parquet and conviction_scores.parquet.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "Statistics"])

using Parquet2
using DataFrames
using Dates
using Statistics

# ---- Configuration ----
const FUNDAMENTALS_PATH = get(ENV, "FUNDAMENTALS_PATH", "/mnt/cache/quant/lake/fundamentals.parquet")
const UNIVERSE_PATH = get(ENV, "UNIVERSE_PATH", "/mnt/cache/quant/lake/universe.parquet")
const VETO_OUTPUT = get(ENV, "VETO_OUTPUT", "/mnt/cache/quant/lake/veto_flags.parquet")
const CONVICTION_OUTPUT = get(ENV, "CONVICTION_OUTPUT", "/mnt/cache/quant/lake/conviction_scores.parquet")

const COMPONENT_WEIGHTS = Dict(
    "f_score" => 0.25,
    "roic_spread" => 0.20,
    "accruals" => 0.20,
    "gm_trend" => 0.15,
    "rev_persistence" => 0.10,
    "revision_breadth" => 0.10,
)

# ---- Altman Z-Score ----
function altman_z(wc, ta, re, ebit, mve, tl, sales)
    if any(ismissing, [wc, ta, re, ebit, mve, tl, sales]) || ta == 0 || tl == 0
        return missing
    end
    return 1.2*(wc/ta) + 1.4*(re/ta) + 3.3*(ebit/ta) + 0.6*(mve/tl) + 1.0*(sales/ta)
end

# ---- Piotroski F-Score ----
function piotroski_f_score(row)
    score = 0
    # Profitability
    roa = row.net_income / row.total_assets
    if roa > 0; score += 1; end
    # ΔROA (simplified: compare to prior quarter if available)
    if !ismissing(row.prior_roa) && roa > row.prior_roa; score += 1; end
    # CFO > 0
    if row.operating_cash_flow > 0; score += 1; end
    # Accruals: CFO/assets > ROA
    if row.operating_cash_flow / row.total_assets > roa; score += 1; end
    # ΔLever < 0 (simplified)
    if !ismissing(row.prior_debt_ratio) && row.long_term_debt / row.total_assets < row.prior_debt_ratio; score += 1; end
    # ΔLiquid > 0 (simplified)
    if !ismissing(row.prior_current_ratio) && row.assets_current / row.liabilities_current > row.prior_current_ratio; score += 1; end
    # No equity issuance (simplified: skip for now, requires share count history)
    # ΔMargin > 0 (simplified)
    if !ismissing(row.prior_gross_margin) && row.gross_profit / row.revenues > row.prior_gross_margin; score += 1; end
    # ΔTurn > 0 (simplified)
    if !ismissing(row.prior_asset_turnover) && row.revenues / row.total_assets > row.prior_asset_turnover; score += 1; end
    return score
end

# ---- Cross-sectional z-score ----
function cross_sectional_z(values::Vector{Union{Float64,Missing}})::Vector{Union{Float64,Missing}}
    valid = collect(skipmissing(values))
    if length(valid) < 10
        return fill(missing, length(values))
    end
    med = median(valid)
    mad = median(abs.(valid .- med))
    if mad == 0
        return fill(missing, length(values))
    end
    z = [(ismissing(v) ? missing : clamp((v - med) / mad, -3.0, 3.0)) for v in values]
    return z
end

# ---- Main ----
function main()
    @info "Computing fundamental overlay"

    fundamentals = DataFrame(Parquet2.read(FUNDAMENTALS_PATH))
    universe = DataFrame(Parquet2.read(UNIVERSE_PATH))

    # Get latest filing per ticker
    fundamentals = sort(fundamentals, [:ticker, :filing_date])
    latest = combine(groupby(fundamentals, :ticker), last)

    # Merge with universe
    eligible = filter(r -> r.eligible, universe)
    latest = innerjoin(latest, eligible, on = :ticker)

    # ---- Veto computation ----
    veto_rows = []
    for row in eachrow(latest)
        z = altman_z(
            row.assets_current - row.liabilities_current,
            row.total_assets, row.retained_earnings, row.ebit,
            row.shares_outstanding * 100,  # placeholder market cap
            row.total_liabilities, row.revenues
        )

        veto = false
        if !ismissing(z) && z < 1.8; veto = true; end
        # Add other triggers as columns become available

        push!(veto_rows, Dict(
            "ticker" => row.ticker,
            "as_of_date" => today(),
            "filing_date" => row.filing_date,
            "altman_z" => z,
            "going_concern" => false,
            "neg_book_neg_ocf" => false,
            "delisting_notice" => false,
            "restatement_12m" => false,
            "auditor_resigned" => false,
            "covenant_breach" => false,
            "veto_active" => veto,
        ))
    end

    veto_df = DataFrame(veto_rows)
    Parquet2.write(VETO_OUTPUT, veto_df)
    @info "Wrote $(nrow(veto_df)) veto rows, $(sum(veto_df.veto_active)) active"

    # ---- Conviction computation ----
    # Compute raw components
    latest.f_score = [piotroski_f_score(row) for row in eachrow(latest)]
    latest.roic_spread = latest.ebit ./ latest.total_assets .- 0.08  # simplified WACC
    latest.accruals = (latest.net_income .- latest.operating_cash_flow) ./ latest.total_assets
    latest.gm_trend = latest.gross_profit ./ latest.revenues  # simplified
    latest.rev_persistence = fill(0.5, nrow(latest))  # placeholder
    latest.revision_breadth = fill(0.0, nrow(latest))  # placeholder

    # Cross-sectional z-scores
    for comp in keys(COMPONENT_WEIGHTS)
        col = Symbol(comp)
        if comp == "accruals"
            # Sign-flip: lower accruals is better
            latest[!, col] = -1.0 .* latest[!, col]
        end
        z_col = Symbol("$(comp)_z")
        latest[!, z_col] = cross_sectional_z(latest[!, col])
    end

    # Composite
    composite = zeros(Union{Float64,Missing}, nrow(latest))
    for i in 1:nrow(latest)
        total = 0.0
        weight_sum = 0.0
        for (comp, w) in COMPONENT_WEIGHTS
            z_col = Symbol("$(comp)_z")
            val = latest[i, z_col]
            if !ismissing(val)
                total += w * val
                weight_sum += w
            end
        end
        composite[i] = weight_sum > 0 ? total / weight_sum : missing
    end
    latest.composite_z = composite

    # Conviction
    latest.conviction = [ismissing(z) ? 1.0 : clamp(1.0 + 0.12*z, 0.50, 1.25) for z in latest.composite_z]
    latest.components_used = [sum(!ismissing(latest[i, Symbol("$(c)_z")]) for c in keys(COMPONENT_WEIGHTS)) for i in 1:nrow(latest)]

    # Output
    conviction_df = select(latest,
        :ticker, :filing_date,
        :f_score_z, :roic_spread_z, :accruals_z,
        :gm_trend_z, :rev_persistence_z, :revision_breadth_z,
        :composite_z, :conviction, :components_used
    )
    rename!(conviction_df, :filing_date => :as_of_date)
    conviction_df.as_of_date = fill(today(), nrow(conviction_df))

    Parquet2.write(CONVICTION_OUTPUT, conviction_df)
    @info "Wrote $(nrow(conviction_df)) conviction rows"
end

main()