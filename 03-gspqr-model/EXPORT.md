# Model Export and Cross-Language Inference

The contract between Julia training and Rust inference. The model file
is the only artifact that crosses the language boundary.

## 1. The Export Format

**LightGBM `.txt`.** Not pickle. Not joblib. Not ONNX. Not PMML.

Why `.txt`:

- **Portable.** Both `bosk` (pure Rust) and `lightgbm-rust` (C bindings)
  parse it natively.
- **Human-readable.** You can open the file and inspect the trees. This
  matters when debugging why a prediction changed.
- **Versionable.** Git diffs of `.txt` model files show exactly which
  trees changed between generations.
- **Stable.** LightGBM guarantees forward compatibility of the text
  format across minor versions.
- **No Python dependency.** A `.txt` model does not require Python,
  LightGBM's Python bindings, or any runtime beyond the parser itself.

## 2. File Naming

    gspqr_<generation>_<horizon>_q<quantile>.txt

Example:

    gspqr_2026-10-01_63d_q05.txt
    gspqr_2026-10-01_63d_q50.txt
    gspqr_2026-10-01_252d_q99.txt

Generation is the training date in ISO format. Horizon is `63d`,
`126d`, or `252d`. Quantile is the integer percentile (`q01`, `q05`,
`q25`, `q50`, `q75`, `q95`, `q99`).

## 3. Feature Name Embedding

LightGBM `.txt` files begin with a header block that includes
`feature_names=...`. This is critical: Rust inference reads the feature
names and asserts they match the frozen order.

If the feature names in the file do not match what Rust expects, the
load fails. This prevents the "I retrained with a different feature
order" bug that would otherwise produce silently wrong predictions.

**Do not strip the feature names from the export.** Do not rename
features on export. The feature names must match the panel column
names exactly.

## 4. Rust Inference

Two options:

### `bosk` (pure Rust)

```rust
use bosk::lightgbm::{LightGBMModel, Predictor};

let model = LightGBMModel::from_file("models/gspqr_2026-10-01_63d_q50.txt")?;
assert_eq!(model.feature_names(), &EXPECTED_FEATURE_ORDER);

let x: Vec<f64> = /* 12 features in frozen order */;
let y_hat: f64 = model.predict(&x)?;
```

Advantages:
- No C dependency
- Cross-compiles trivially (any target, any OS)
- Small binary size
- Pure Rust safety

Disadvantages:
- Slightly slower than the C API for large batch predictions
- May lag LightGBM feature support (e.g., custom objectives)

For a 3–12 month model that runs inference once per day, "slower" is
irrelevant. `bosk` is the recommended default.

### `lightgbm-rust` (C bindings)

```rust
use lightgbm::{Booster, Dataset};

let booster = Booster::from_file("models/gspqr_2026-10-01_63d_q50.txt")?;
let y_hat = booster.predict(&x, true)?;
```

Advantages:
- Full LightGBM feature set
- Same code path as training
- Faster on large batches

Disadvantages:
- Requires `lib_lightgbm.so` at runtime
- Complicates cross-compilation
- Adds a C dependency to the Rust build

Use only if `bosk` is missing a feature you need. For standard quantile
regression, it is not.

## 5. Batch Inference

For daily inference across the universe:

```rust
pub async fn predict_all(
    models: &ModelSet,
    panel: &Panel,
) -> Result<Vec<PredictionRow>, InferenceError> {
    let mut rows = Vec::with_capacity(panel.len() * 21);

    for horizon in [Horizon::D63, Horizon::D126, Horizon::D252] {
        for ticker in panel.tickers() {
            let x = panel.feature_vector(ticker, horizon);
            for (tau, model) in models.for_horizon(horizon) {
                let q = model.predict(&x)?;
                rows.push(PredictionRow {
                    ticker: ticker.clone(),
                    date: panel.date(),
                    horizon: horizon.label(),
                    quantile: tau,
                    value: q,
                });
            }
        }
    }

    Ok(rows)
}
```

The result is written to `gspqr_predictions.parquet` with one row per
(ticker, date, horizon) and seven quantile columns. See
`13-parquet-lake/SCHEMAS.md` §7.

## 6. Feature Vector Construction in Rust

The 12 features come from the panel. Rust reads the panel, filters to
the current date, and builds a 12-element vector per ticker.

```rust
const EXPECTED_FEATURE_ORDER: [&str; 12] = [
    "mom_20d", "mom_60d", "mom_12m_1m",
    "vol_60d_res", "sp_ratio", "turn_20d",
    "r_mom_20d", "r_mom_60d", "r_mom_12m_1m",
    "r_vol_60d", "r_sp", "r_turn",
];

fn feature_vector(row: &PanelRow) -> [f64; 12] {
    [
        row.mom_20d,
        row.mom_60d,
        row.mom_12m_1m,
        row.vol_60d_res,
        row.sp_ratio,
        row.turn_20d,
        row.r_mom_20d,
        row.r_mom_60d,
        row.r_mom_12m_1m,
        row.r_vol_60d,
        row.r_sp,
        row.r_turn,
    ]
}
```

NaN features are passed through as `f64::NAN`. `bosk` handles them the
same way LightGBM does.

## 7. The Round-Trip Test

Before deploying a new generation, run a round-trip test:

1. Pick 100 rows from the validation set.
2. Compute Julia predictions for each row using the newly trained models.
3. Compute Rust predictions for the same rows using the same models.
4. Assert `max(abs(julia - rust)) < 1e-6`.

This test catches:

- Feature order mismatches (predictions differ wildly)
- NaN handling differences (predictions differ on rows with NaN)
- Parser bugs in `bosk`
- LightGBM version mismatches between training and inference

The test lives in `tests/export_roundtrip.rs` and runs in CI on every
commit that touches `models/` or `EXPORT.md`.

If the test fails, do not deploy. Fix the mismatch first.

## 8. What Not to Do

- Do not export to pickle, joblib, or any Python-specific format. Rust
  cannot read them.
- Do not export to ONNX. It adds a dependency and loses the tree
  structure that makes debugging possible.
- Do not strip feature names from the export.
- Do not rename features between training and inference.
- Do not assume `bosk` and `lightgbm-rust` produce identical output.
  Test both if you switch.
- Do not skip the round-trip test. Silent prediction drift is the worst
  class of bug in a quant system.
- Do not deploy a model generation whose `.txt` files have been
  manually edited. Regenerate from training.