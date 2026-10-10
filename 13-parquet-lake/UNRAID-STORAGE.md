# Unraid Filesystem Correction: XFS, Not ZFS

The skills contain several references to ZFS that need to be corrected for your XFS setup. Below is every location that mentions ZFS and the exact replacement text.

---

## 1. `13-parquet-lake/UNRAID-STORAGE.md`

This is the file with the most ZFS references. Here is the complete corrected version:

```markdown
# Unraid Storage Layout

This system runs on Unraid. Storage paths and pool rules matter because
a misconfiguration silently destroys query performance.

## Storage Tiers

| Tier | Path | Purpose | Redundancy |
|---|---|---|---|
| Cache pool (NVMe, XFS) | `/mnt/cache/quant/` | Live Parquet lake, DuckDB workspace, model artifacts | Single drive or XFS on a pool |
| Appdata | `/mnt/cache/appdata/quant/` | Container state, logs, SQLite locks, config | Same pool as cache |
| Array (HDD, XFS, parity) | `/mnt/user/quant-backup/` | Daily rsync of cache pool | Unraid parity |
| Boot | `/boot/config/plugins/` | Unraid plugins, User Scripts | USB flash |

**Rule:** All live reads and writes go to the cache pool. The array is
read-only backup. Never write a Parquet file to `/mnt/user/`.

## Filesystem Notes

Unraid uses **XFS** as the default filesystem for both the array and
cache pools. XFS is a mature, high-performance filesystem well-suited
to this workload. Two implications:

**No native snapshots.** XFS does not support snapshots in the mainline
kernel. The nightly rsync to the array is the backup mechanism. If
snapshot-style point-in-time recovery is desired, it must be done at the
application layer (e.g., copy Parquet files to a timestamped directory
before a schema migration).

**No checksumming.** XFS does not checksum data blocks the way ZFS does.
Silent bit rot is possible. Mitigation: the nightly rsync verifies file
size and modification time, and the schema registry hash (in
`schemas/registry.json`) detects schema-level corruption. For
data-level integrity, add a periodic `parquet-tools` or DuckDB
read-through validation job that reads every file and checks row counts
and null percentages against expected values.

**Cache pool configuration.** XFS on a single NVMe drive is the simplest
configuration. If redundancy is desired, Unraid supports a cache pool
with two drives. However, Unraid's cache pool redundancy for XFS uses
**btrfs RAID1**, not XFS mirroring. For an XFS-only setup, a single
cache drive is the norm, and the nightly array backup is the safety net.

## Directory Structure on Cache Pool

```
/mnt/cache/quant/
├── lake/
│   ├── universe.parquet
│   ├── prices/
│   │   ├── year=2024/month=01/data.parquet
│   │   ├── year=2024/month=02/data.parquet
│   │   └── ...
│   ├── fundamentals.parquet
│   ├── macro.parquet
│   ├── panel/
│   │   └── year=YYYY/month=MM/data.parquet
│   ├── regime_states.parquet
│   ├── gspqr_predictions/
│   │   └── year=YYYY/month=MM/data.parquet
│   ├── tcp_calibration/
│   │   └── year=YYYY/month=MM/data.parquet
│   ├── evt_residuals/
│   │   └── year=YYYY/month=MM/data.parquet
│   ├── evt_tail_bounds.parquet
│   ├── conviction_scores.parquet
│   ├── veto_flags.parquet
│   ├── portfolio_targets.parquet
│   ├── position_locks.parquet
│   ├── pending_orders.parquet
│   ├── orders.parquet
│   ├── positions.parquet
│   ├── fills.parquet
│   ├── evaluation_metrics.parquet
│   ├── data_quality.parquet
│   └── audit_log.parquet
├── models/
│   ├── gspqr_<train_date>.txt
│   └── registry.json
├── schemas/
│   └── registry.json
└── migrations/
    ├── 2026-10-10-initial.md
    └── ...
```

## Unraid Share Configuration

The share backing `/mnt/cache/quant/` must be configured:

- **Primary storage:** Cache
- **Secondary storage:** Array (for backup only)
- **Allocation method:** High-water
- **Mover action:** Cache → Array (nightly, for backup copy)
- **Minimum free space:** 20 GB (prevents cache pool exhaustion)

**Critical:** If `Mover action` is set to "Array → Cache" or "Cache: yes"
without care, the mover will move live Parquet files from cache to array
overnight. Your next morning's DuckDB query will be 100× slower. Set the
mover action explicitly and verify it after any Unraid version update.

## Container Mounts

| Container | Mount | Mode | Notes |
|---|---|---|---|
| `quant-core` (Julia + Rust) | `/mnt/cache/quant:/data` | rw | Only writer of the lake |
| `quant-core` | `/mnt/cache/appdata/quant:/state` | rw | Logs, SQLite |
| `quant-api` (Bun) | `/mnt/cache/quant:/data` | ro | Read-only, no writes |
| `duckdb` | `/mnt/cache/quant:/data` | ro | Read-only, debug queries |

The read-only mounts enforce the single-writer rule from the constitution
at the filesystem level. Bun cannot accidentally overwrite a Parquet file
because the kernel refuses the write.

## UID/GID Mapping

Unraid uses UID 99 (`nobody`) and GID 100 (`users`) for share access.
Containers must run with matching UID/GID or they will fail to write.

```yaml
# In the Dockerfile or run command
user: "99:100"
```

If a container needs a different UID, chown the target directory:

```bash
chown -R 1000:1000 /mnt/cache/quant/
```

But prefer running as 99:100. Mixing UIDs across containers leads to
permission confusion and silent write failures.

## Docker Image Storage

On Unraid 7+, Docker image storage options depend on the filesystem:

- **If the Docker image lives on the XFS cache pool:** use the `overlay2`
  storage driver. Do not use the legacy `native` driver; it has known
  stability issues on non-ZFS pools.
- **If using a separate Docker image file:** a single `docker.img` file
  on the cache pool. Monitor its size; when it fills, Docker stops
  working.

**Settings → Docker → Docker image storage:** set to the cache pool path.
**Default appdata storage:** `/mnt/cache/appdata/`.
**Enable Docker custom networks:** yes.
**Host access to custom networks:** enabled.
**Custom network type:** ipvlan (not macvlan).

## Backup Script

Nightly at 18:00, rsync the cache pool to the array. This is a backup,
not a migration. Do not delete the source after.

```bash
#!/usr/bin/env bash
set -euo pipefail

SRC=/mnt/cache/quant/
DST=/mnt/user/quant-backup/

rsync -a --delete --exclude='*.tmp' "$SRC" "$DST"

# Log the result
DATE=$(date +%F)
echo "$DATE backup completed: $(du -sh "$DST" | cut -f1)" \
  >> /mnt/cache/appdata/quant/logs/backup.log
```

The array is slower, so the backup takes 10–30 minutes for a few GB.
Do not run it during market hours.

**Note on XFS and rsync:** rsync on XFS is reliable but does not verify
data integrity beyond file size and mtime. For stronger verification,
add a `--checksum` flag to rsync, which forces a content hash comparison
at the cost of a slower backup. Given the Parquet files are a few GB
total, `--checksum` is affordable and recommended:

```bash
rsync -a --checksum --delete --exclude='*.tmp' "$SRC" "$DST"
```

## Integrity Monitoring (XFS, No Snapshots)

Since XFS does not provide snapshots, the following monitoring is
required:

| Check | Frequency | Tool |
|---|---|---|
| Schema hash matches registry | Daily | `scripts/verify-schemas.sh` |
| Row count per Parquet file | Weekly | DuckDB `SELECT COUNT(*)` |
| Null percentage per critical column | Weekly | DuckDB `SELECT AVG(...)` |
| File size and mtime | Daily | `find` + comparison log |
| Full read-through of all Parquet | Monthly | DuckDB read-all script |

A full read-through job reads every Parquet file and asserts the row
count is greater than zero and the schema matches the registry. This is
the substitute for ZFS's automatic checksumming.

## What Breaks on Unraid

| Symptom | Cause | Fix |
|---|---|---|
| Parquet queries 100× slower after a night | Mover moved files to array | Set share mover action to Cache → Array, verify |
| Write failures "permission denied" | Container running as wrong UID | Set `user: "99:100"` |
| Docker stops working | `docker.img` full | Expand it or move to cache pool path |
| Random kernel crashes | macvlan on bridge | Switch to ipvlan |
| GPU not detected | Unraid update broke driver | Regenerate CDI, pin Unraid version |

## What Does Not Break on Unraid

The constitution, the schemas, the pipeline logic, the language boundaries,
the 5-day lock, the point-in-time rules. None of these are affected by
the host OS or the filesystem. If you find yourself changing one of them
"for Unraid," you are solving the wrong problem.