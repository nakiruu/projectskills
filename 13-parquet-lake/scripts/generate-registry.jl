#!/usr/bin/env julia
# Regenerates schemas/registry.json from the current Parquet files.
# Run after any schema change. Commits the result.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "JSON3", "SHA"])

using Parquet2
using JSON3
using SHA

const LAKE_ROOT = get(ENV, "LAKE_ROOT", "/mnt/cache/quant/lake")
const REGISTRY  = get(ENV, "REGISTRY",  "/mnt/cache/quant/schemas/registry.json")

const FILES = [
    ("universe.parquet",            "julia-universe",   false),
    ("prices.parquet",              "rust-ingest",      true),
    ("fundamentals.parquet",        "rust-ingest",      false),
    ("macro.parquet",               "rust-ingest",      false),
    ("panel.parquet",               "julia-panel",      true),
    ("regime_states.parquet",       "julia-regime",     false),
    ("gspqr_predictions.parquet",   "julia-gspqr",      true),
    ("tcp_calibration.parquet",     "julia-tcp",        true),
    ("evt_residuals.parquet",       "julia-evt",        true),
    ("evt_tail_bounds.parquet",     "julia-evt",        false),
    ("conviction_scores.parquet",   "julia-conviction", false),
    ("veto_flags.parquet",          "julia-conviction", false),
    ("portfolio_targets.parquet",   "julia-portfolio",  false),
    ("position_locks.parquet",      "rust-lock",        false),
    ("pending_orders.parquet",      "rust-order",       false),
    ("orders.parquet",              "rust-exec",        false),
    ("positions.parquet",           "rust-exec",        false),
    ("fills.parquet",               "rust-exec",        false),
    ("evaluation_metrics.parquet",  "julia-backtest",   false),
    ("data_quality.parquet",        "rust-ingest",      false),
    ("audit_log.parquet",           "rust-eventbus",    false),
]

function find_sample(name::String, partitioned::Bool)::Union{String,Nothing}
    path = joinpath(LAKE_ROOT, name)
    if isfile(path)
        return path
    end
    if partitioned
        stem = replace(name, ".parquet" => "")
        dir = joinpath(LAKE_ROOT, stem)
        if isdir(dir)
            for (root, _, files) in walkdir(dir)
                for f in files
                    if endswith(f, ".parquet")
                        return joinpath(root, f)
                    end
                end
            end
        end
    end
    return nothing
end

function schema_hash(path::String)::Tuple{String,Int}
    pf = Parquet2.Dataset(path)
    names = Parquet2.column_names(pf)
    types = Parquet2.column_types(pf)
    repr = join(["$(names[i]):$(types[i])" for i in eachindex(names)], "|")
    return (bytes2hex(sha256(repr)), length(names))
end

registry = Dict{String,Any}()
for (name, writer, partitioned) in FILES
    sample = find_sample(name, partitioned)
    if isnothing(sample)
        @warn "Not found: $name (skipping)"
        continue
    end
    h, ncols = schema_hash(sample)
    registry[name] = Dict(
        "hash"           => h,
        "columns"        => ncols,
        "partitioned"    => partitioned,
        "writer"         => writer,
        "last_migration" => "2026-10-10-initial",
    )
end

open(REGISTRY, "w") do io
    JSON3.pretty(io, registry)
end

println("Wrote registry with $(length(registry)) entries to $REGISTRY")