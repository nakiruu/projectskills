# Shadow Execution Engine

Because Schwab has no paper trading environment, the adapter runs a
shadow engine that simulates fills and compares them against real fills
after deployment.

## 1. What It Does

For every order the adapter is about to submit:

1. Fetch the current quote (bid, ask, last).
2. Simulate the fill using a tier-specific slippage model.
3. Record the simulated fill in `shadow_fills.parquet`.
4. Submit the real order.
5. When the real fill arrives, compare.

## 2. The Slippage Model

The simulated fill price depends on the execution tier:

### Standard tier (limit orders)

    simulated_fill = mid_price + (direction × slippage_bps × mid_price / 10000)

Where:
- `mid_price = (bid + ask) / 2`
- `direction = +1` for buy, `-1` for sell
- `slippage_bps = 5` (default)

### Transition tier (limit orders)

Same as Standard. The limit order controls the fill price; the modeled
slippage of 5 bps represents the expected cost of crossing a partial
spread when the limit is at or near the mid.

### Transition tier (fractional market orders)

    simulated_fill = direction == Buy ? ask : bid

The market order crosses the spread. The fill is at the quoted ask for
buys and the quoted bid for sells. No slippage parameter is applied
beyond the spread itself, because the spread is the cost.

### Bootstrap tier (market orders)

    simulated_fill = direction == Buy ? ask : bid

Same as the Transition fractional case. The full spread is the cost.

## 3. Divergence Detection

After the real fill:

    divergence_bps = (real_fill - simulated_fill) / mid_price × 10000

If `abs(divergence_bps) > 20`, log a `WARN` to `audit_log.parquet`. If
`abs(divergence_bps) > 50` for 3 consecutive orders, halt trading and
require manual review.

The threshold is the same for all tiers. A market order that diverges by
more than 50 bps from the quoted spread is unusual and indicates either a
stale quote or a data problem.

## 4. What the Shadow Engine Is Not

- It is not a backtest. It runs on live quotes.
- It is not a substitute for real testing. It is a guardrail.
- It does not simulate partial fills. Real fills may be partial; the
  shadow engine assumes full fill at the simulated price.
- It does not model queue position for limit orders. A limit order at the
  bid may or may not fill depending on order flow. The shadow engine
  assumes it fills at the limit price if the price touches it.

## 5. Schema

`shadow_fills.parquet`:

| Column | Type | Notes |
|---|---|---|
| `order_id` | `utf8` | FK to orders |
| `ticker` | `utf8` | |
| `side` | `utf8` | `Buy` / `Sell` |
| `quantity` | `float64` | Fractional permitted |
| `order_type` | `utf8` | `Limit` / `Market` |
| `tier` | `utf8` | `Bootstrap` / `Transition` / `Standard` |
| `bid_at_submit` | `float64` | |
| `ask_at_submit` | `float64` | |
| `mid_at_submit` | `float64` | |
| `simulated_fill` | `float64` | |
| `slippage_bps` | `float64` | Realized slippage vs mid |
| `real_fill` | `float64` | Null until filled |
| `divergence_bps` | `float64` | Null until filled |

The `quantity` is `float64` rather than `int64` to accommodate fractional
orders in the Bootstrap and Transition tiers.

The `tier` column records which slippage model was applied. This allows
post-hoc comparison: the average slippage in the Bootstrap tier is
expected to be higher than in the Standard tier, and the divergence
analysis must be done per tier.

## 6. Tier-Specific Slippage Calibration

The `slippage_bps` parameter is calibrated from historical fills. The
calibration is done separately per tier:

| Tier | Calibration source | Expected slippage |
|---|---|---|
| Bootstrap | Bootstrap-tier market fills only | Half spread, ~5–20 bps depending on liquidity |
| Transition (limit) | Transition-tier limit fills only | ~5 bps |
| Transition (market) | Transition-tier market fills only | Half spread |
| Standard | Standard-tier limit fills only | ~5 bps |

Calibrating across tiers would mix market-order spread cost with
limit-order fill cost. The separation ensures the simulator reflects the
actual cost structure of each tier.

After 50 real fills in a tier, the median slippage for that tier is
recomputed and the parameter is updated.

## 7. What Not to Do

- Do not use the shadow engine to decide whether to submit. It runs
  alongside, not before.
- Do not skip the divergence check. It catches adapter bugs.
- Do not assume simulated = real. Measure.
- Do not calibrate slippage across tiers. Each tier has its own cost
  structure.
- Do not apply a fixed slippage parameter to market orders. The cost is
  the spread, not a fixed bps value.
- Do not record a fractional order with an integer quantity column. The
  schema uses `float64` for a reason.