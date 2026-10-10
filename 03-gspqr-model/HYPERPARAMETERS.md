# Hyperparameters

The defaults for each of the 21 GSPQR models. These are starting
points, not fixed truths. A tuning pass may revise them, but the
structure (one model per quantile, chronological splits, fixed feature
order) is frozen.

## 1. LightGBM Parameters

| Parameter | Value | Rationale |
|---|---|---|
| `objective` | `"quantile"` | We are fitting quantiles, not the mean |
| `alpha` | the quantile level | 0.05 for q_05, 0.50 for q_50, etc. |
| `metric` | `"quantile"` | Consistent with objective |
| `boosting` | `"gbdt"` | Standard gradient boosting |
| `num_leaves` | 31 | Standard starting point; low overfitting risk |
| `learning_rate` | 0.05 | Moderate; slow enough to converge |
| `n_estimators` | 500 | Upper bound; early stopping will cut |
| `max_depth` | -1 | No limit; `num_leaves` is the real constraint |
| `min_data_in_leaf` | 100 | Prevents overfitting on rare feature combinations |
| `min_sum_hessian_in_leaf` | 1e-3 | Default; fine for quantile regression |
| `feature_fraction` | 0.8 | Column subsampling per tree |
| `bagging_fraction` | 0.8 | Row subsampling per iteration |
| `bagging_freq` | 5 | Bag every 5 iterations |
| `lambda_l1` | 0.1 | L1 regularization on leaf weights |
| `lambda_l2` | 0.1 | L2 regularization on leaf weights |
| `max_bin` | 255 | Default; fewer bins = less overfitting |
| `use_missing` | true | Handle NaN natively |
| `zero_as_missing` | false | Treat zero as a real value |
| `verbose` | -1 | Suppress LightGBM's stdout noise |
| `seed` | 42 | Reproducibility |
| `num_threads` | -1 | Use all available cores |

## 2. Per-Quantile Adjustments

Extreme quantiles (q_01, q_99) are harder to fit because they are
defined by the tails. Two adjustments help:

| Quantile | Adjustment |
|---|---|
| q_01, q_99 | `min_data_in_leaf = 200` (double the default) |
| q_01, q_99 | `n_estimators = 800` (more trees for tail resolution) |
| q_25, q_75 | `n_estimators = 400` (fewer, they converge faster) |
| q_50 | `n_estimators = 500` (default) |

The rationale: extreme quantile regression is essentially a
classification problem at a very imbalanced threshold (1% vs 99%).
More data per leaf and more trees help resolve the tail.

## 3. Early Stopping

Set `early_stopping_rounds = 50` with the validation set. Training
stops when the validation metric has not improved in 50 iterations.

The validation set is the **last 20% of train dates** for each ticker.
This is a chronological split, not random. See `TRAINING.md` §2.

**Do not use the `cal` or `test` splits for early stopping.** They are
reserved for calibration and evaluation respectively.

## 4. What Is Not Tuned

The following are deliberately fixed:

- **Objective function.** Always `"quantile"`. Never `"regression"`,
  `"huber"`, or a custom loss.
- **Boosting type.** Always `"gbdt"`. Not `"dart"`, not `"goss"`.
- **Feature set.** Always the 12 columns from the panel. No additions
  without a skill amendment and a backtest.
- **Feature order.** Frozen. Reordering invalidates every model.

If a tuning pass wants to change one of these, it is a skill amendment,
not a tuning result.

## 5. Tuning Protocol

When tuning is needed (new feature set, regime change, periodic review):

1. Define a validation metric. Use **pinball loss** on the validation
   set, aggregated across quantiles with equal weight.
2. Set a tuning budget. Grid search over 3 values per parameter, no
   more. Bayesian optimization is overkill for 21 models.
3. Tune `num_leaves` ∈ {15, 31, 63} first. This is the highest-impact
   parameter.
4. Tune `min_data_in_leaf` ∈ {50, 100, 200} second.
5. Tune `learning_rate` × `n_estimators` together: {(0.05, 500),
   (0.03, 800), (0.1, 300)}.
6. Leave the regularization parameters at defaults unless overfitting is
   observed.
7. Tune each horizon separately. A 63-day model and a 252-day model have
   different signal-to-noise ratios.

**Never tune on the test set.** The test set is for final evaluation
only. Tuning on it inflates reported performance and is a form of
lookahead.

## 6. Overfitting Detection

Signs a model is overfit:

- Train pinball loss is >30% lower than validation pinball loss
- Validation coverage deviates from nominal by >5 percentage points
- Feature importance is concentrated in one or two features (>60%)
- Performance on `cal` split is much worse than on the validation
  subset of `train`

If any of these appear, reduce `num_leaves`, increase
`min_data_in_leaf`, or increase `lambda_l1`/`lambda_l2`.

## 7. Reproducibility

Set `seed = 42` and `deterministic = true` (LightGBM option). This
ensures the same training data produces the same model. Do not change
the seed between the tuning pass and the final training.

If a retrain produces a different model than the previous run on the
same data, something is non-deterministic. Investigate before deploying.