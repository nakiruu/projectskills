# Training Protocol

The step-by-step procedure for training a GSPQR model generation.

## 1. Inputs

- `panel.parquet` — the 12-feature panel with forward return targets
- `registry.json` — the previous generation's metrics (for comparison)

## 2. Splitting

The panel has a `split` column with values `train`, `cal`, `test`,
assigned per ticker chronologically (see `02-panel-construction/TARGETS.md` §4).

GSPQR trains on `split == train` only. Within the train rows, a further
chronological split creates a validation set:

    1. Sort train rows by date.
    2. Find the 80th percentile date.
    3. Rows on or before that date: training set.
    4. Rows after that date: validation set.

This is per-horizon. A 63-day model uses rows where `y_fwd_63d` is
non-NaN. A 252-day model uses rows where `y_fwd_252d` is non-NaN. The
two sets overlap but are not identical.

**Why 80/20 within train:** Early stopping needs a held-out set that
is not the `cal` or `test` splits. The validation set is used only for
early stopping and overfitting detection, not for calibration or final
evaluation.

## 3. Feature Matrix

For horizon H:

    X_train = panel[split == "train" & date <= val_boundary, FEATURES]
    y_train = panel[same, y_fwd_Hd]
    X_val   = panel[split == "train" & date > val_boundary, FEATURES]
    y_val   = panel[same, y_fwd_Hd]

Where `FEATURES` is the frozen 12-column list in order. NaN values are
preserved, not imputed.

Drop rows where `y_train` or `y_val` is NaN. Keep rows where features
are NaN.

## 4. Training One Model

For each (horizon, quantile) pair:

```julia
params = Dict(
    "objective"        => "quantile",
    "alpha"            => tau,
    "metric"           => "quantile",
    "num_leaves"       => num_leaves,
    "learning_rate"    => learning_rate,
    "min_data_in_leaf" => min_data_in_leaf,
    "feature_fraction" => 0.8,
    "bagging_fraction" => 0.8,
    "bagging_freq"     => 5,
    "lambda_l1"        => 0.1,
    "lambda_l2"        => 0.1,
    "verbose"          => -1,
    "seed"             => 42,
    "num_threads"      => -1,
)

train_set = LightGBM.Dataset(X_train, label = y_train, free_raw_data = false)
val_set   = LightGBM.Dataset(X_val,   label = y_val,   reference = train_set)

model = LightGBM.fit(
    train_set, val_set;
    params = params,
    num_boost_round = n_estimators,
    early_stopping_rounds = 50,
    verbose_eval = false,
)
```

The `alpha` parameter is set to the target quantile level. Everything
else is from `HYPERPARAMETERS.md`, adjusted per-quantile as specified.

## 5. Saving the Model

```julia
save_path = "models/gspqr_$(generation)_$(horizon)_q$(round(Int, tau*100)).txt"
LightGBM.save(model, save_path)
```

The `.txt` format is LightGBM's native text serialization. It is
human-readable, versionable in Git, and portable across LightGBM
versions with forward compatibility guarantees.

## 6. Evaluating the Model

For each model, compute on the validation set:

**Pinball loss** (the primary metric):

    pinball(y, yhat, tau) = mean(
        tau * (y - yhat) if y >= yhat
        (1 - tau) * (yhat - y) if y < yhat
    )

**Coverage** (the fraction of validation rows where `y <= yhat`):

    coverage = mean(y_val .<= yhat_val)

For a well-calibrated model at quantile τ, coverage should be close to
τ. A coverage of 0.10 for a q_05 model indicates the model is
under-predicting the tail; 0.02 indicates over-predicting.

**Record both metrics** in the registry. They are the primary inputs
to the deploy/don't-deploy decision.

## 7. Abort Conditions

Abort the retrain and keep the previous generation if ANY of:

- Any model's validation pinball loss is more than 10% worse than the
  previous generation's
- Any model's validation coverage deviates from nominal by more than
  10 percentage points
- More than 3 of the 21 models fail to train (converge, produce finite
  predictions)
- Training runs longer than 6 hours for the full generation

On abort, log to `audit_log.parquet` with `severity = "WARN"` and
`event_type = "model_retrain_aborted"`. The live model remains the
previous generation.

## 8. Deployment

After successful training and evaluation:

1. Copy the new `.txt` files to `models/`.
2. Update `registry.json` with the new generation entry.
3. Archive the previous generation to `models/archive/<date>/`.
4. Commit the new registry to Git.
5. Restart the Rust inference service to pick up the new registry.

The Rust service loads models lazily. A restart is not required for
every retrain; the service polls the registry's mtime and reloads on
change. But an explicit restart during off-hours is safer.

## 9. Reproducibility

Given the same `panel.parquet` and the same seed, training must produce
byte-identical model files. If it does not:

- Check that `deterministic = true` is set in the LightGBM params
- Check that `num_threads` does not vary (LightGBM's threading can be
  non-deterministic on some operations)
- Check that the input panel is identical (hash it before training)

Any non-determinism is a bug. Investigate before deploying.

## 10. Verification Checklist

Before deploying:

- [ ] All 21 `.txt` files exist and are non-empty
- [ ] Each file's first line lists the feature names in the frozen order
- [ ] Validation pinball loss is recorded for each model
- [ ] Validation coverage is recorded for each model
- [ ] No model triggered an abort condition
- [ ] The registry is updated with the new generation
- [ ] The previous generation is archived (not deleted)
- [ ] A Rust inference test reproduces Julia predictions on 100 rows
      to within 1e-6
- [ ] The commit message references the generation date and the
      validation metrics
