#!/usr/bin/env julia
# Daily reconciliation: local positions vs Schwab positions.
# Mismatch halts trading. Runs after market close.

using Pkg
Pkg.activate(temp=true)
Pkg.add(["Parquet2", "DataFrames", "Dates", "JSON3", "HTTP"])

using Parquet2
using DataFrames
using Dates
using JSON3
using HTTP

const LOCAL_POSITIONS = get(ENV, "LOCAL_POSITIONS",
    "/mnt/cache/quant/lake/positions.parquet")
const SCHWAB_BASE = "https://api.schwabapi.com"
const STATE_DIR = get(ENV, "STATE_DIR", "/mnt/cache/appdata/quant/state")

function get_access_token()::String
    token_path = joinpath(STATE_DIR, "schwab_access_token")
    if !isfile(token_path)
        error("Access token not found. Run OAuth flow first.")
    end
    return read(token_path, String) |> strip
end

function fetch_schwab_positions()::DataFrame
    token = get_access_token()
    # In production: look up account hash from config
    account_hash = ENV["SCHWAB_ACCOUNT_HASH"]

    resp = HTTP.get(
        "$SCHWAB_BASE/trader/v1/accounts/$account_hash?fields=positions",
        headers = ["Authorization" => "Bearer $token"],
    )

    if resp.status != 200
        error("Schwab API returned $(resp.status)")
    end

    data = JSON3.read(String(resp.body))
    positions = data.securitiesAccount.positions

    rows = []
    for p in positions
        push!(rows, Dict(
            "ticker" => p.instrument.symbol,
            "shares" => p.longQuantity,
            "avg_cost" => p.averagePrice,
        ))
    end

    return DataFrame(rows)
end

function main()
    @info "Reconciling positions"

    local_pos = DataFrame(Parquet2.read(LOCAL_POSITIONS))
    local_pos = filter(r -> r.shares > 0, local_pos)

    schwab_pos = fetch_schwab_positions()

    # Compare
    local_tickers = Set(local_pos.ticker)
    schwab_tickers = Set(schwab_pos.ticker)

    missing_in_schwab = setdiff(local_tickers, schwab_tickers)
    missing_in_local = setdiff(schwab_tickers, local_tickers)

    mismatches = 0

    if !isempty(missing_in_schwab)
        @error "Tickers in local but not Schwab: $missing_in_schwab"
        mismatches += 1
    end

    if !isempty(missing_in_local)
        @error "Tickers in Schwab but not local: $missing_in_local"
        mismatches += 1
    end

    # Compare share counts for shared tickers
    for ticker in intersect(local_tickers, schwab_tickers)
        local_shares = local_pos[local_pos.ticker .== ticker, :shares][1]
        schwab_shares = schwab_pos[schwab_pos.ticker .== ticker, :shares][1]

        if local_shares != schwab_shares
            @error "$ticker: local=$local_shares, schwab=$schwab_shares"
            mismatches += 1
        end
    end

    if mismatches > 0
        @error "Reconciliation FAILED with $mismatches mismatches. HALT TRADING."
        # Write halt flag
        halt_path = joinpath(STATE_DIR, "TRADING_HALTED")
        write(halt_path, "Reconciliation failed at $(now())")
        exit(1)
    else
        @info "Reconciliation OK: $(nrow(local_pos)) positions match"
    end
end

main()