# Order Construction

How to build each supported order type. All orders are limit-family.
No market orders.

## 1. Limit Order

The primary order type. Buy or sell at a specified price or better.

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

## 2. Stop Order

Triggers a market order when the stop price is reached. **Use with
caution** — the resulting market order violates the constitution's
no-market-order rule. **Do not use stop orders in this system.**

## 3. Stop-Limit Order

Triggers a limit order when the stop price is reached. This is the
correct risk-exit order.

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

## 4. Trailing Stop

A dynamic stop that follows the price. Requires `stopPriceBasis`
(`LAST`, `BID`, `ASK`), `stopPriceType` (`VALUE` or `PERCENT`), and
`stopPriceOffset` .

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
exits .

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

Entry + stop-loss + take-profit in one submission.

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

## 8. What Not to Do

- Do not use `Market` orders.
- Do not use `Stop` (plain) orders. The resulting market order is
  forbidden.
- Do not use extended hours sessions.
- Do not use `FillOrKill` without a specific reason.
- Do not build OCO or bracket orders manually. Use the builder.