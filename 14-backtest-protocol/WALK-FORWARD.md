# Walk-Forward

The simple walk-forward variant, used for early stopping during model
training, not for final evaluation.

## 1. What It Is

Walk-forward analysis divides the timeline into sequential folds. Each
fold trains on all data before the test block and tests on the next
block. The window can be **expanding** (training set grows) or
**sliding** (training set stays a fixed size) .

```
Fold 1: [====TRAIN====][TEST]
Fold 2: [=======TRAIN=======][TEST]
Fold 3: [==========TRAIN==========][TEST]
```

## 2. Purging and Embargoing

Simple walk-forward still has a leak: if the label horizon extends into
the test period, training observations near the boundary "see" test
data. Purge removes training rows whose label overlaps the test block.
Embargo removes training rows immediately **after** the test block
(though in walk-forward, there are no post-test training rows, so
embargo is a no-op) .

`PortfolioOptimisers.jl`'s `WalkForwardEstimator` accepts a
`purged_size` parameter (default 5) for the pre-test boundary .

## 3. When to Use Walk-Forward

Walk-forward is used **only for early stopping during GSPQR training**.
It is not used for final evaluation because:

- It produces a single path, not a distribution.
- The Sharpe ratio estimate has high variance .
- It cannot generate the multiple paths needed for statistical
  significance testing.

## 4. The Training Loop

During GSPQR training (see `03-gspqr-model/TRAINING.md`):

1. Use `split == train` rows.
2. Split the train rows into training and validation by date (last 20%
   of train dates for validation).
3. Train with early stopping on the validation set.

This is a simple 80/20 chronological split, not full walk-forward. The
full walk-forward is not needed during training because we are not
evaluating strategy performance — we are selecting the number of
boosting rounds.

## 5. What Not to Do

- Do not use walk-forward for final evaluation. Use CPCV.
- Do not use `KFold` or `train_test_split` for time series. Use
  `TimeSeriesSplit` or `PurgedKFold` .
- Do not skip purging in walk-forward. Overlapping labels leak.
- Do not assume `shuffle=False` makes `KFold` safe. Every fold but the
  last still trains on future rows .