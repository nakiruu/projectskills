# Shadow Execution Engine

Because Schwab has no paper trading environment , the adapter
runs a shadow engine that simulates fills and compares them against
real fills after deployment.

## 1. What It Does

For every order the adapter is about to submit:

1. Fetch the current quote (bid, ask, last).
2. Simulate the fill using a slippage model.
3. Record the simulated fill in `shadow_fills.parquet`.
4. Submit the real order.
5. When the real fill arrives, compare.

## 2. The Slippage Model

The simulated fill price is:

    simulated_fill = mid_price + (direction × slippage_bps × mid_price / 10000)

Where:
- `mid_price = (bid + ask) / 2`
- `direction = +1` for buy, `-1` for sell
- `slippage_bps = 5` (default, 5 basis points)

The slippage parameter is calibrated from historical fills. After 50
real fills, recompute the median slippage and update the parameter.

## 3. Divergence Detection

After the real fill:

    divergence_bps = (real_fill - simulated_fill) / mid_price × 10000

If `abs(divergence_bps) > 20`, log a `WARN` to `audit_log.parquet`. If
`abs(divergence_bps) > 50` for 3 consecutive orders, halt trading and
require manual review.

## 4. What the Shadow Engine Is Not

- It is not a backtest. It runs on live quotes.
- It is not a substitute for real testing. It is a guardrail.
- It does not simulate partial fills. Real fills may be partial; the
  shadow engine assumes full fill at the simulated price.

## 5. Schema

`shadow_fills.parquet`:

| Column | Type | Notes |
|---|---|---|
| `order_id` | `utf8` | FK to orders |
| `ticker` | `utf8` | |
| `side` | `utf8` | `Buy` / `Sell` |
| `quantity` | `int64` | |
| `bid_at_submit` | `float64` | |
| `ask_at_submit` | `float64` | |
| `mid_at_submit` | `float64` | |
| `simulated_fill` | `float64` | |
| `slippage_bps` | `float64` | |
| `real_fill` | `float64` | Null until filled |
| `divergence_bps` | `float64` | Null until filled |

## 6. What Not to Do

- Do not use the shadow engine to decide whether to submit. It runs
  alongside, not before.
- Do not skip the divergence check. It catches adapter bugs.
- Do not assume simulated = real. Measure.