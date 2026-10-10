Here is `CROSS-SECTIONAL.md` as a standalone markdown file:

```markdown
# Cross-Sectional Rank Features

Ranks transform raw features into relative signals. They answer "is this
stock's momentum high compared to its peers today?" rather than "is
momentum high in absolute terms?"

## 1. What Ranks Are

For each raw feature and each date `t`, the rank of ticker `i` is its
position in the cross-sectional distribution of that feature across all
eligible tickers on `t`:

    r_feat[i, t] = rank of feat[i, t] among {feat[j, t] : j in universe(t)}

Ranks are scaled to [0, 1]:

    scaled_rank = (rank - 1) / (N - 1)

Where `rank` is the 1-based rank and `N` is the number of eligible
tickers. The smallest value gets 0, the largest gets 1.

## 2. Why Ranks, Not Raw Z-Scores

Cross-sectional Z-scores and ranks differ in how they handle outliers.

- A Z-score of 3 for one stock pulls the mean and standard deviation,
  distorting every other stock's Z.
- A rank of 1 for one stock doesn't affect any other stock's rank.

For financial features with fat tails, ranks are more robust. The GSPQR
paper uses ranks for this reason.

## 3. Tie Handling

Ties are broken by average rank. If three stocks tie for ranks 5, 6, 7,
each gets rank 6.

DuckDB: `PERCENT_RANK()` or `CUME_DIST()`. In Polars: `rank(method='average')`.
In Julia: `StatsBase.ordinalrank` then average within tie groups, or use
`DataFrames.rank`.

## 4. Universe Requirement

Ranks are computed per date across the **eligible universe**. Eligible
means:

- In `universe.parquet` with `eligible = true` on date `t`
- Has a non-NaN value for the raw feature on date `t`

If the eligible count `N < 50`, all ranks on that date are NaN. The
system refuses to produce ranks on too-small cross-sections.

**Why 50:** Below 50, the rank distribution is too coarse to be
informative. A rank of 1 out of 20 is 5% top; out of 500 it's 0.2% top.
These are different signals, and the model was trained on the latter.

**Mag7 note:** With only 7 tickers, ranks are 0, 1/6, 2/6, ..., 1. The
values are still computable, but the model cannot learn rank-based
signals from such a coarse cross-section. The universe must be expanded
to IWF + IWP before ranks become meaningful.

## 5. Per-Feature Details

The six rank columns and their source features:

| Rank column | Source | Direction |
|---|---|---|
| `r_mom_20d` | `mom_20d` | Higher is better |
| `r_mom_60d` | `mom_60d` | Higher is better |
| `r_mom_12m_1m` | `mom_12m_1m` | Higher is better |
| `r_vol_60d` | `vol_60d_res` | Lower is better (sign-flipped) |
| `r_sp` | `sp_ratio` | Higher is better |
| `r_turn` | `turn_20d` | Higher is better |

**Sign flip for `r_vol_60d`:** Low volatility is the desirable signal.
The rank is computed on `-vol_60d_res`, so high rank means low volatility.

**Sign flip for `r_sp`:** Not sign-flipped. High sales-to-price is a
value signal; higher is better.

## 6. Implementation

The canonical implementation is in `features/ranks.jl`:

```julia
function cross_sectional_rank(
    df::DataFrame;
    feature_col::Symbol,
    universe_col::Symbol = :eligible,
    date_col::Symbol = :date,
)::Vector{Union{Float64,Missing}}
    n = nrow(df)
    result = Vector{Union{Float64,Missing}}(missing, n)

    for (date, group) in pairs(groupby(df, date_col))
        # Filter to eligible tickers with non-missing feature
        mask = coalesce.(group[!, universe_col], false) .&
               .!ismissing.(group[!, feature_col])
        idx = findall(mask)
        N = length(idx)

        if N < 50
            continue  # leave as missing
        end

        vals = group[idx, feature_col]
        ranks = StatsBase.ordinalrank(vals)
        # Convert to average-rank within ties
        avg_ranks = average_ranks_within_ties(vals, ranks)
        scaled = (avg_ranks .- 1) ./ (N - 1)
        result[group[idx, :row_id]] = scaled
    end

    return result
end
```

## 7. Verification

- [ ] A test on synthetic data with known ranks produces the expected
      output
- [ ] A test asserts NaN when eligible count < 50
- [ ] A test asserts ties are broken by average rank
- [ ] A test asserts `r_vol_60d` is sign-flipped
- [ ] A test asserts no rank uses future data

## 8. What Not to Do

- Do not compute ranks on the full universe including ineligible names.
  Only eligible tickers on the date count.
- Do not include tickers with NaN raw features in the rank computation.
  They are excluded from the distribution, and their rank is NaN.
- Do not use `N` = total universe size when computing the scaling
  denominator. Use the number of eligible tickers with non-NaN features.
- Do not compute ranks with fewer than 50 names. Return NaN.
- Do not use raw Z-score instead of rank. The GSPQR paper uses ranks for
  a reason.
