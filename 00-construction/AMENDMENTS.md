# Constitution Amendment Log

Append-only. Every change to SKILL.md adds a row. Never edit a past row.

| Version | Date       | Invariant | Change                          | Rationale                          | PR  |
|---------|------------|-----------|---------------------------------|------------------------------------|-----|
| 1.0     | 2026-10-10 | all       | Initial ratification            | Project inception                  | #1  |
| 1.1     | 2026-10-10 | §5, §8    | Permit in-place update of `tax_lots.parquet` on full close; permit reduction of `open_quantity` on partial close with a new row for the closed portion | FIFO lot tracking requires mutating the open lot when partially closed. This is the only sanctioned update path for a non-audit file. `audit_log.parquet` remains strictly append-only. `portfolio_ledger.parquet` is append-only for new days. | #2 |
| 1.2     | 2026-10-10 | §6        | Replace "Limit orders only" with a three-tier NAV-based execution model. Under $2,500 NAV: fractional market orders only. $2,500–$10,000 NAV: limit orders are the majority; market orders permitted for fractional shares only. Above $10,000 NAV: limit orders only. | Schwab rounds limit orders up to whole shares and enforces minimums that a sub-$1,000 account cannot meet. The tiers make the system operable at small capital while preserving the limit-order discipline at scale. | #3 |

## Amendment Template

Copy this into a new row when proposing a change:

| Version | Date | Invariant | Change | Rationale | PR |
|---|---|---|---|---|---|
| x.y | YYYY-MM-DD | §N | one-line description | why the old rule failed | #NN |

## Rules for Amending

- One invariant per amendment. Do not bundle.
- The PR must update every skill listed in CROSS-REFERENCE.md for that invariant.
- If the amendment removes a rule, state what replaces it. No silent deletions.
- If more than 2 amendments land in a quarter, the constitution is carrying
  detail that belongs in layer-specific skills. Move it.

## Deprecation Log

Rules that were once constitutional but were demoted to skills. Keep this
list so future readers understand why the constitution is short.

| Rule (removed) | Date demoted | Now lives in |
|---|---|---|
| (none yet) | — | — |

## Amendment Detail: 1.1

**Invariants affected:** §5 (Parquet schema immutability, extended to append-only), §8 (Audit log).

**Change:** `tax_lots.parquet` may be updated in place on a full close and may have `open_quantity` reduced on a partial close, with a new row written for the closed portion.

**Scope:** Only `tax_lots.parquet`. `audit_log.parquet` remains strictly append-only. `portfolio_ledger.parquet` is append-only for new days, with the idempotency overwrite being a defensive measure on re-run, not a normal update path.

**Skills updated in the same PR:**
- `16-portfolio-ledger` (defines the update pattern)
- `13-parquet-lake` (schema for `tax_lots.parquet`)

## Amendment Detail: 1.2

**Invariant affected:** §6 (Execution constraints).

**Change:** The rule "Limit orders only. Never submit a market order to Schwab" is replaced by a three-tier NAV-based execution model.

**Tiers:**
- Bootstrap (< $2,500): fractional market orders only
- Transition ($2,500–$10,000): limit orders default; market orders for fractional remainder only
- Standard (> $10,000): limit orders only

**Scope:** The tier is determined by the trailing 5-day mean NAV, read at order submission time, not cached. The 5-day lock applies in all tiers.

**Skills updated in the same PR:**
- `10-execution-schwab` (§1, §2, §2a, §6)
- `10-execution-schwab/ORDER-TYPES.md` (§1, §1a, §8, §9)
- `10-execution-schwab/SHADOW-ENGINE.md` (§2, §5, §6, §7)
- `08-portfolio-optimization` (§6, new §6a and §6b)
- `14-backtest-protocol` (§6, new §6a, §6b, §6c)
- `16-portfolio-ledger` (§1, §5, §8)
- `11-rust-event-bus/EVENT-TYPES.md` (`OrderSubmitted`, `OrderFilled`)
