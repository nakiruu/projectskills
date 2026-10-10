# Constitution Amendment Log

Append-only. Every change to SKILL.md adds a row. Never edit a past row.

| Version | Date       | Invariant | Change                          | Rationale                          | PR  |
|---------|------------|-----------|---------------------------------|------------------------------------|-----|
| 1.0     | 2026-10-10 | all       | Initial ratification            | Project inception                  | #1  |
| 1.1 | 2026-10-10 | §5, §8 | Permit in-place update of `tax_lots.parquet` on full close; permit reduction of `open_quantity` on partial close with a new row for the closed portion | FIFO lot tracking requires mutating the open lot when partially closed. This is the only sanctioned update path for a non-audit file. `audit_log.parquet` remains strictly append-only. `portfolio_ledger.parquet` is append-only for new days. | #NN |

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