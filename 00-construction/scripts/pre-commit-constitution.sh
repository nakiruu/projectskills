#!/usr/bin/env bash
# Fast checks that catch the most common constitutional violations before
# a commit lands. Slow checks (schema hashes, full test suite) run in CI.
set -euo pipefail

fail() { echo "CONSTITUTION VIOLATION: $1" >&2; exit 1; }

# §2 — period_end must not appear in decision code
if git diff --cached --name-only | grep -E '^(features|models|backtest|portfolio|conviction)/' | xargs -r grep -l 'period_end' 2>/dev/null; then
  fail "period_end used in decision code (§2). Use filing_date."
fi

# §3 — no random splits outside the approved module
if git diff --cached --name-only | xargs -r grep -l -E 'train_test_split|KFold\(' 2>/dev/null \
   | grep -v 'backtest/splits.jl'; then
  fail "random split outside backtest/splits.jl (§3)."
fi

# §6 — market orders
if git diff --cached --name-only | grep -E '^execution/' | xargs -r grep -l -iE 'OrderType::Market|"market"' 2>/dev/null; then
  fail "market order reference in execution layer (§6)."
fi

# §4 — language boundaries
while read -r f; do
  case "$f" in
    models/*|portfolio/*|regime/*|conviction/*) [[ "$f" == *.jl ]] || fail "$f: expected .jl (§4)";;
    execution/*|ingest/*|risk/*)                [[ "$f" == *.rs ]] || fail "$f: expected .rs (§4)";;
    frontend/*|api/*)                            [[ "$f" == *.ts || "$f" == *.tsx ]] || fail "$f: expected .ts (§4)";;
  esac
done < <(git diff --cached --name-only --diff-filter=ACM)

echo "Constitution pre-commit checks passed."