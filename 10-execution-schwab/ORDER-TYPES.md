# Order Construction

How to build each supported order type. The order type is determined by
the current NAV tier (see `SKILL.md` §2a). Fractional quantities are only
expressible as market orders; limit orders are rounded up to whole shares.

## 1. Limit Order (Transition and Standard tiers)

The default order type above $2,500 NAV. Buy or sell at a specified price
or better. Schwab rounds limit quantities up to whole shares.

```rust
let order = LimitOrder::builder()
    .symbol("AAPL")
    .instruction(Instruction::Buy)
    .quantity(25)
    .limit_price(Decimal::new(18750, 2))  // $187.50
    .duration(Duration::Day)
    .session(Session::Normal)
    .build()?;
```

In the Transition tier, a limit order is used for the integer portion of
a target quantity. The fractional remainder is submitted separately as a
market order (see §1a).

## 1a. Market Order (Bootstrap tier, and Transition fractional)

The only order type below $2,500 NAV. Supports fractional quantities.
The spread is paid in full.

```rust
let order = MarketOrder::builder()
    .symbol("AAPL")
    .instruction(Instruction::Buy)
    .quantity(Decimal::new(150, 2))   // 1.50 shares
    .duration(Duration::Day)
    .session(Session::Normal)
    .build()?;
```

Market orders are only constructible when the current execution tier
permits them. Attempting to construct a `MarketOrder` while the tier is
Standard returns `ExecutionTierError::MarketOrderNotPermitted` at build
time, not at submission time.

In the Transition tier, a market order is only used for the fractional
remainder after a whole-share limit has been submitted for the integer
portion. It is never used for the full quantity when the full quantity is
expressible as whole shares.

## 2. Stop Order

Triggers a market order when the stop price is reached. **Do not use stop
orders in this system.** The resulting market order is only permitted in
the Bootstrap tier, and in that tier the system does not use stops
because the lock already limits exposure. Use `StopLimit` instead.

## 3. Stop-Limit Order

Triggers a limit order when the stop price is reached. This is the
correct risk-exit order above $2,500 NAV.

```rust
let order = StopLimitOrder::builder()
    .symbol("AAPL")
    .instruction(Instruction::Sell)
    .quantity(25)
    .stop_price(Decimal::new(18000, 2))   // trigger at $180
    .limit_price(Decimal::new(17950, 2))  // limit at $179.50
    .duration(Duration::Day)
    .build()?;
```

In the Bootstrap tier, `StopLimit` is not used because it requires whole
shares. Risk exits are market orders for the full position.

## 4. Trailing Stop

A dynamic stop that follows the price. Requires `stopPriceBasis`
(`LAST`, `BID`, `ASK`), `stopPriceType` (`VALUE` or `PERCENT`), and
`stopPriceOffset`. Not used in the Bootstrap tier.

```rust
let order = TrailingStopOrder::builder()
    .symbol("AAPL")
    .instruction(Instruction::Sell)
    .quantity(25)
    .stop_price_basis(PriceBasis::Bid)
    .stop_price_type(PriceType::Percent)
    .stop_price_offset(Decimal::new(10, 0))  // 10% trail
    .build()?;
```

## 5. OCO (One-Cancels-Other)

Two linked orders. When one fills, the other cancels. Used for bracket
exits above $2,500 NAV. Not used in the Bootstrap tier.

```rust
let oco = OcoOrder::builder()
    .leg(StopLimitOrder::builder()
        .instruction(Instruction::Sell)
        .stop_price(Decimal::new(18000, 2))
        .limit_price(Decimal::new(17950, 2))
        .build()?)
    .leg(LimitOrder::builder()
        .instruction(Instruction::Sell)
        .limit_price(Decimal::new(22000, 2))
        .build()?)
    .build()?;
```

## 6. Bracket Order

Entry + stop-loss + take-profit in one submission. Requires whole-share
quantities. Not used in the Bootstrap tier.

```rust
let bracket = BracketOrder::builder()
    .entry(LimitOrder::builder()
        .instruction(Instruction::Buy)
        .limit_price(Decimal::new(18750, 2))
        .build()?)
    .stop_loss(StopLimitOrder::builder()
        .instruction(Instruction::Sell)
        .stop_price(Decimal::new(17500, 2))
        .limit_price(Decimal::new(17450, 2))
        .build()?)
    .take_profit(LimitOrder::builder()
        .instruction(Instruction::Sell)
        .limit_price(Decimal::new(21000, 2))
        .build()?)
    .build()?;
```

## 7. Duration and Session

| Field | Values | Default |
|---|---|---|
| `duration` | `Day`, `GoodTillCancel`, `FillOrKill` | `Day` |
| `session` | `Normal`, `AM`, `PM` | `Normal` |

The system uses `Day` and `Normal`. Extended hours are not used because
liquidity is thin and the lock constraint makes after-hours fills risky.

## 8. Tier-to-Order-Type Matrix

| Tier | NAV | Primary order type | Fallback | Fractional |
|---|---|---|---|---|
| Bootstrap | < $2,500 | Market | — | Yes |
| Transition | $2,500 – $10,000 | Limit | Market (fractional only) | For fractional only |
| Standard | > $10,000 | Limit | — | No |

The tier is read from `portfolio_ledger.parquet` at submission time. The
order generator consults the tier before constructing the order. The
`Market` variant of the `OrderType` enum is only constructible when the
tier is Bootstrap, or when the tier is Transition and the quantity has a
fractional remainder.

## 9. What Not to Do

- Do not use `Market` orders outside the Bootstrap tier or the Transition
  tier's fractional path.
- Do not use `Stop` (plain) orders. The resulting market order is
  forbidden in all tiers above Bootstrap.
- Do not use extended hours sessions.
- Do not use `FillOrKill` without a specific reason.
- Do not build OCO or bracket orders manually. Use the builder.
- Do not submit a fractional limit order. Schwab rounds them up to whole
  shares. Use a market order for fractional quantities.
- Do not cache the execution tier across orders. Read it at submission
  time.