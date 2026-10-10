#!/usr/bin/env julia
# Round-trip test: Julia prediction vs Rust prediction on the same model.
# Run before deploying a new model generation.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Arrow", "LightGBM"])

using Parquet2
using DataFrames
using Arrow
using LightGBM

const PANEL_PATH = get(ENV, "PANEL_PATH", "/mnt/cache/quant/lake/panel.parquet")
const MODEL_PATH = get(ENV, "MODEL_PATH", "/mnt/cache/quant/models/gspqr_2026-10-01_63d_q50.txt")

const FEATURES = [
    :mom_20d, :mom_60d, :mom_12m_1m,
    :vol_60d_res, :sp_ratio, :turn_20d,
    :r_mom_20d, :r_mom_60d, :r_mom_12m_1m,
    :r_vol_60d, :r_sp, :r_turn,
]

function main()
    @info "Round-trip test: $MODEL_PATH"

    # Load 100 rows from the panel
    panel = DataFrame(Parquet2.read(PANEL_PATH))
    sample = first(panel, 100)

    # Build feature matrix
    X = Matrix{Float64}(sample[!, FEATURES])

    # Load model in Julia
    model = LightGBM.load(MODEL_PATH)

    # Julia predictions
    julia_preds = LightGBM.predict(model, X)

    # Write features and Julia predictions to Arrow for Rust
    Arrow.write("roundtrip_features.arrow", sample[!, FEATURES])
    Arrow.write("roundtrip_julia_preds.arrow", DataFrame(pred = julia_preds))

    @info "Wrote features and Julia predictions to Arrow"
    @info "Run the Rust side to produce roundtrip_rust_preds.arrow"
    @info "Then compare with: julia compare-roundtrip.jl"
end

main()