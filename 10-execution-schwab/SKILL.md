---
name: execution-schwab
description: Schwab API client and order lifecycle. Load when touching
  execution/schwab/, order submission, OAuth, or position reconciliation.
---

# Schwab Execution

The Schwab adapter is the last code between a portfolio target and a real
order. It is Rust-only. It runs in the execution hot path. It is the
narrowest, most rule-bound module in the system.

## 1. The Hard Constraints

From the constitution (§6):

- **Limit orders only.** No market orders. The order type enum does not
  include `Market`.
- **No shorts.** Long-only. `SELL_SHORT` is not representable.
- **Position cap.** Resulting weight ≤ 5% per name.
- **Sector cap.** Resulting weight ≤ 25% per GICS sector.
- **Cash buffer.** Resulting cash ≥ 2% of portfolio value.
- **Daily reconciliation.** Local positions vs Schwab positions. Mismatch
  halts trading.

These are compile-time or pre-submit runtime checks. An order cannot
reach Schwab without passing them.

## 2. Order Types Supported

From Schwab's Trader API :

| Type | Supported | Notes |
|---|---|---|
| `Limit` | ✅ | Primary order type |
| `Stop` | ✅ | For risk exits |
| `StopLimit` | ✅ | Stop with limit protection |
| `TrailingStop` | ✅ | Dynamic stop |
| `Market` | ❌ | Forbidden by constitution |
| `MarketOnClose` | ❌ | Forbidden (not limit) |
| `LimitOnClose` | ✅ | Limit at close |
| `OCO` | ✅ | One-cancels-other for bracket exits |
| `OTO` | ✅ | One-triggers-other |
| `Bracket` | ✅ | Entry + stop + take-profit |

See `ORDER-TYPES.md` for construction patterns.

## 3. OAuth 2.0

See `OAUTH.md`. The critical facts:

- Access token valid ~30 minutes 
- Refresh token valid ~7 days 
- **No paper environment.** Schwab has no sandbox . The adapter
  trades real money. A shadow engine simulates fills for validation.
- Refresh token expiry requires re-authorization by the account owner
  .

The token refresh is a single POST to Schwab's token endpoint. The
adapter stores the refresh token in the state directory with restrictive
permissions. When the refresh token expires, `BrokerAuthExpired` is
raised and trading halts until the owner re-authorizes.

## 4. Rate Limits

Schwab enforces rate limits per OAuth app/user token .
Numeric limits are behind the developer portal login and not publicly
published. Order endpoints have lower limits than read-only queries
.

**Policy:** Exponential backoff on 429. Honor `Retry-After` header.
Do not retry order submissions blindly; check order status first.

## 5. The Shadow Execution Engine

See `SHADOW-ENGINE.md`. Because there is no paper environment, the
adapter runs a shadow engine that:

1. Simulates fills using the current quote + slippage model
2. Compares simulated P&L against real P&L after live deployment
3. Flags divergence between simulation and reality

The shadow engine is not a substitute for real testing. It is a guardrail
against deploying a code change that produces obviously wrong fills.

## 6. Order Lifecycle

```
CREATED ──submit──▶ PENDING ──fill──▶ FILLED
                       │
                       ├──partial──▶ PARTIAL ──fill──▶ FILLED
                       │
                       ├──reject──▶ REJECTED
                       │
                       └──cancel──▶ CANCELLED
```

Schwab rejects bad orders **after** accepting them . The
order is created, then shows up as `REJECTED`. The adapter keeps rejected
orders visible until they reach a final state.

**Critical:** An order that appears accepted may still be rejected
minutes later. The adapter polls order status until a terminal state.

## 7. What Not to Do

- Do not submit market orders. The enum forbids it.
- Do not assume an order is filled because it was accepted. Poll until
  terminal.
- Do not retry a rejected order without understanding why.
- Do not skip daily reconciliation. The local state drifts.
- Do not store the refresh token in plaintext.
- Do not run the adapter in a container without the state mount.
- Do not call the bridge from the order submission path.

## 8. Verification

- [ ] No `Market` order type exists in the enum
- [ ] No `SELL_SHORT` instruction exists
- [ ] Pre-submit checks for position, sector, and cash caps
- [ ] Reconciliation runs daily and halts on mismatch
- [ ] OAuth token refresh is tested with a mock server
- [ ] Shadow engine produces fills within expected slippage
- [ ] A test submits a limit order far from market and cancels it

## 9. Related Skills

- `00-constitution` §6 — execution constraints
- `09-lock-state-machine` — order gating
- `11-rust-event-bus` — where order events are dispatched
- `12-julia-rust-bridge` — the bridge that is not used here
