---
name: gspqr-model
description: LightGBM quantile regression for the GSPQR base model.
  Load when touching models/gspqr/, training code, hyperparameter tuning,
  or the model export path.
---

# GSPQR Model

GSPQR is the base quantile model. It takes the 12-feature panel (see
`02-panel-construction`) and produces conditional quantile estimates of
forward excess returns at three horizons.

## 1. What GSPQR Produces

For each ticker, date, and horizon, GSPQR emits seven quantiles:

| Quantile | Purpose |
|---|---|
| `q_01` | 1st percentile — extreme downside |
| `q_05` | 5th percentile — the TCP lower bound input |
| `q_25` | 25th percentile — lower quartile |
| `q_50` | 50th percentile — **median, used by the optimizer** |
| `q_75` | 75th percentile — upper quartile |
| `q_95` | 95th percentile — the TCP upper bound input |
| `q_99` | 99th percentile — extreme upside |

These are **raw** quantiles, before TCP calibration. The calibration
layer (see `04-tcp-calibration`) turns `q_05` and `q_95` into valid
prediction intervals. EVT (see `05-evt-tails`) extends `q_01` and `q_99`
using extreme value theory.

## 2. Architecture

**One LightGBM model per (horizon, quantile) pair.** That is 3 horizons
× 7 quantiles = 21 models.

Why not one model with multiple outputs: LightGBM's quantile objective
is defined per quantile. Training a single multi-output model requires
either a custom objective or a wrapper, both of which complicate
inference and export. Separate models are simpler, faster to train in
parallel, and each model's output is independently interpretable.

**The models do not share trees.** Each is fit independently on the
same features against the same target, differing only in the quantile
level.

## 3. Training Discipline

Three non-negotiables:

- **Chronological splits only.** The panel's `split` column is
  `train`/`cal`/`test`, assigned per ticker chronologically. GSPQR
  trains on `split == train` rows only. Never shuffle.
- **NaN is a valid feature value.** LightGBM handles NaN natively. Do
  not impute, do not drop rows with NaN features. The only rows dropped
  are those where the target for the horizon being modeled is NaN.
- **Fixed feature order.** The 12 features are always in the order
  specified in `02-panel-construction/FEATURES.md` §7. Reordering
  invalidates every trained model. The export step embeds the feature
  names, and Rust inference asserts them on load.

## 4. Training Cadence

| Trigger | Action |
|---|---|
| Monthly (first trading day) | Full retrain of all 21 models |
| Daily after market close | Inference only — no retraining |
| Manual | Full retrain on demand via `scripts/train-gspqr.jl` |

Retraining monthly, not daily, because:

- The panel updates daily, but the feature distribution shifts slowly.
- Monthly retrain prevents the model from chasing noise.
- Each retrain is a fresh set of 21 models; the previous generation is
  archived, not overwritten.

**Model registry:** `models/registry.json` tracks every trained model
generation, its training date, training set size, and validation metrics.
See §6.

## 5. Hyperparameters

See `HYPERPARAMETERS.md`. The defaults are:

    objective        = "quantile"
    alpha            = <the quantile level>
    num_leaves       = 31
    learning_rate    = 0.05
    n_estimators     = 500
    min_data_in_leaf = 100
    feature_fraction = 0.8
    bagging_fraction = 0.8
    bagging_freq     = 5
    lambda_l1        = 0.1
    lambda_l2        = 0.1
    max_depth        = -1

These are **defaults**. A tuning pass may revise them. The structure
(one model per quantile, fixed feature order, chronological training)
is frozen.

## 6. Model Registry

`models/registry.json`:

```json
{
  "generation": "2026-10-01",
  "trained_at": "2026-10-01T07:14:22Z",
  "panel_version": "2026-10-01",
  "train_rows": 312847,
  "train_tickers": 612,
  "models": {
    "63d_q_05": {
      "path": "models/gspqr_2026-10-01_63d_q05.txt",
      "feature_names": ["mom_20d", "mom_60d", "..."],
      "train_metric": 0.041,
      "val_metric": 0.044
    },
    "63d_q_50": { "...": "..." },
    "...": {}
  }
}
```

Each entry includes the model path, the exact feature names (in order),
and the training and validation metrics. Rust inference reads the
registry to know which generation is live and asserts the feature names
match its expected order.

## 7. Export Format

See `EXPORT.md`. The short version:

- LightGBM's native `.txt` model format.
- One `.txt` file per model.
- No serialization via pickle, joblib, or any language-specific format.
- Rust loads via `bosk` (pure-Rust parser) or `lightgbm-rust` (C API).

The `.txt` format is portable, human-readable, versionable in Git, and
reproducible across machines. It is the only sanctioned export format.

## 8. Training Protocol

See `TRAINING.md` for the step-by-step procedure. The summary:

1. Load `panel.parquet`, filter to `split == train`.
2. Split the train rows into a **training set** and a **validation set**
   by date. The validation set is the last 20% of train dates. This is
   a further chronological split, not random.
3. For each (horizon, quantile), fit a LightGBM model with early
   stopping on the validation set.
4. Save each model as `.txt`.
5. Evaluate each model on the validation set: pinball loss, coverage
   of the nominal quantile.
6. If any model's validation metric is worse than the previous
   generation by more than 10%, abort the retrain and keep the old
   generation.
7. Update `registry.json`.

## 9. Feature Matrix Construction

The 12 features come from the panel in this exact order:

    mom_20d, mom_60d, mom_12m_1m, vol_60d_res, sp_ratio, turn_20d,
    r_mom_20d, r_mom_60d, r_mom_12m_1m, r_vol_60d, r_sp, r_turn

The feature matrix `X` has shape `(n_rows, 12)`. The target vector `y`
for horizon H is `y_fwd_Hd` from the panel, filtered to non-NaN rows.

**NaN handling:** Do NOT fill NaN. Pass the matrix with NaN directly to
LightGBM. The `use_missing=true` default handles it.

**Do not standardize or normalize.** The raw features and rank features
are already on comparable scales (ranks are [0, 1]; raw features are
unbounded but LightGBM is scale-invariant on splits).

## 10. What Not to Do

- Do not train a single multi-output model. One model per quantile.
- Do not shuffle rows. Chronological only.
- Do not impute NaN features. Pass them through.
- Do not standardize features. LightGBM does not need it.
- Do not use a random validation split. The validation set is the last
  20% of train dates.
- Do not export via pickle or joblib. `.txt` only.
- Do not overwrite a previous model generation. Archive and version.
- Do not tune hyperparameters on the test set. Tune on validation.
- Do not train on the full panel including `cal` and `test` rows. Train
  on `split == train` only.
- Do not reorder the feature matrix. The order is frozen.

## 11. Verification

Before deploying a new model generation:

- [ ] All 21 models exist and are readable `.txt` files
- [ ] Each model's feature names match the frozen order
- [ ] Each model's validation pinball loss is within 10% of the
      previous generation
- [ ] Coverage of the nominal quantile on the validation set is within
      ±5 percentage points of nominal
- [ ] A Rust inference test loads one model and reproduces Julia's
      predictions on 100 held-out rows to within 1e-6
- [ ] `registry.json` is updated and committed
- [ ] The previous generation is archived, not deleted

## 12. Related Skills

- `02-panel-construction` — produces the input features
- `04-tcp-calibration` — consumes `q_05` and `q_95`
- `05-evt-tails` — consumes `q_01` and `q_99`
- `08-portfolio-optimization` — consumes `q_50` as expected return
- `12-julia-rust-bridge` — the export/load path
- `13-parquet-lake` — schema for `gspqr_predictions.parquet`
- `14-backtest-protocol` — evaluates the model
```