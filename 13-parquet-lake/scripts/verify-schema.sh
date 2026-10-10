
---

## `scripts/verify-schemas.sh`

```bash
#!/usr/bin/env bash
# Verifies every Parquet file's schema matches its registered hash.
# Runs in CI and pre-commit. Fails loudly on mismatch.
set -euo pipefail

LAKE_ROOT="${LAKE_ROOT:-/mnt/cache/quant/lake}"
REGISTRY="${REGISTRY:-/mnt/cache/quant/schemas/registry.json}"

if [[ ! -f "$REGISTRY" ]]; then
  echo "FAIL: registry not found at $REGISTRY" >&2
  exit 1
fi

if ! command -v duckdb >/dev/null 2>&1; then
  echo "FAIL: duckdb CLI not found" >&2
  exit 1
fi

python3 - "$LAKE_ROOT" "$REGISTRY" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

lake_root = Path(sys.argv[1])
registry_path = Path(sys.argv[2])
registry = json.loads(registry_path.read_text())

failures = []

for filename, meta in registry.items():
    # Find the file (or glob for partitioned files)
    candidates = list(lake_root.rglob(filename))
    if not candidates:
        # Partitioned files use a glob
        stem = filename.replace(".parquet", "")
        candidates = list((lake_root / stem).rglob("*.parquet"))
        if not candidates:
            failures.append(f"{filename}: not found")
            continue

    sample = candidates[0]
    # DuckDB DESCRIBE returns column_name, column_type, null, key, default, extra
    result = subprocess.run(
        ["duckdb", "-json", "-c",
         f"DESCRIBE SELECT * FROM read_parquet('{sample}')"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode != 0:
        failures.append(f"{filename}: DESCRIBE failed: {result.stderr.strip()}")
        continue

    schema = json.loads(result.stdout)
    schema_repr = "|".join(
        f"{row['column_name']}:{row['column_type']}" for row in schema
    )
    actual_hash = hashlib.sha256(schema_repr.encode()).hexdigest()

    if actual_hash != meta["hash"]:
        failures.append(
            f"{filename}: schema hash mismatch "
            f"(expected {meta['hash'][:12]}..., got {actual_hash[:12]}...)"
        )

if failures:
    print("SCHEMA VERIFICATION FAILED:", file=sys.stderr)
    for f in failures:
        print(f"  {f}", file=sys.stderr)
    sys.exit(1)

print(f"OK: {len(registry)} schemas verified")
PY