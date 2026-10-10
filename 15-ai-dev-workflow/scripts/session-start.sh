#!/usr/bin/env bash
# Run at the start of every session. Fails loudly if the environment is not
# ready for work.
set -euo pipefail

ok()   { echo "  [ok]   $1"; }
fail() { echo "  [FAIL] $1" >&2; }

echo "Session start checks:"

# 1. Julia MCP alive
if command -v julia >/dev/null 2>&1; then
  if julia --project -e 'using Pkg; Pkg.status()' >/dev/null 2>&1; then
    ok "Julia project loads"
  else
    fail "Julia project does not load (missing deps?)"
  fi
else
  fail "julia not on PATH"
fi

# 2. Rust toolchain
if command -v cargo >/dev/null 2>&1; then
  ok "cargo present"
else
  fail "cargo not on PATH"
fi

# 3. Bun
if command -v bun >/dev/null 2>&1; then
  ok "bun present"
else
  fail "bun not on PATH"
fi

# 4. DuckDB reachable (via CLI or MCP)
if command -v duckdb >/dev/null 2>&1; then
  ok "duckdb present"
else
  echo "  [warn] duckdb CLI not found (MCP may still work)"
fi

# 5. Pre-commit hook installed
if [[ -x .git/hooks/pre-commit ]]; then
  if grep -q "pre-commit-constitution" .git/hooks/pre-commit 2>/dev/null; then
    ok "constitution pre-commit hook installed"
  else
    fail "pre-commit hook exists but is not the constitution hook"
  fi
else
  fail "constitution pre-commit hook not installed"
  echo "         run: ln -sf ../../.claude/skills/00-constitution/scripts/pre-commit-constitution.sh .git/hooks/pre-commit"
fi

# 6. Last commit did not violate constitution
if git log -1 --pretty=%B | grep -qiE 'fix.*later|skip.*check|disable.*lint'; then
  echo "  [warn] last commit message mentions skipping a check"
fi

# 7. Schema registry present
if [[ -f schemas/registry.json ]]; then
  ok "schema registry present"
else
  fail "schemas/registry.json missing"
fi

# 8. Working tree clean (or note what is dirty)
if [[ -z "$(git status --porcelain)" ]]; then
  ok "working tree clean"
else
  echo "  [note] working tree has uncommitted changes:"
  git status --porcelain | head -5 | sed 's/^/         /'
fi

echo
echo "If all checks passed, read .claude/skills/00-constitution/SKILL.md,"
echo "then the skill for your layer, then start work."