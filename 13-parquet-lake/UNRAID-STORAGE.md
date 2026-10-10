# Unraid Storage Layout

This system runs on Unraid. Storage paths and pool rules matter because
a misconfiguration silently destroys query performance.

## Storage Tiers

| Tier | Path | Purpose | Redundancy |
|---|---|---|---|
| Cache pool (NVMe, ZFS mirror) | `/mnt/cache/quant/` | Live Parquet lake, DuckDB workspace, model artifacts | ZFS mirror |
| Appdata | `/mnt/cache/appdata/quant/` | Container state, logs, SQLite locks, config | ZFS mirror |
| Array (HDD, parity) | `/mnt/user/quant-backup/` | Daily rsync of cache pool | Unraid parity |
| Boot | `/boot/config/plugins/` | Unraid plugins, User Scripts | USB flash |

**Rule:** All live reads and writes go to the cache pool. The array is
read-only backup. Never write a Parquet file to `/mnt/user/`.

## Directory Structure on Cache Pool

/mnt/cache/quant/
├── lake/
│ ├── universe.parquet
│ ├── prices/
│ │ ├── year=2024/month=01/data.parquet
│ │ ├── year=2024/month=02/data.parquet
│ │ └── ...
│ ├── fundamentals.parquet
│ ├── macro.parquet
│ ├── panel/
│ │ └── year=YYYY/month=MM/data.parquet
│ ├── regime_states.parquet
│ ├── gspqr_predictions/
│ │ └── year=YYYY/month=MM/data.parquet
│ ├── tcp_calibration/
│ │ └── year=YYYY/month=MM/data.parquet
│ ├── evt_residuals/
│ │ └── year=YYYY/month=MM/data.parquet
│ ├── evt_tail_bounds.parquet
│ ├── conviction_scores.parquet
│ ├── veto_flags.parquet
│ ├── portfolio_targets.parquet
│ ├── position_locks.parquet
│ ├── pending_orders.parquet
│ ├── orders.parquet
│ ├── positions.parquet
│ ├── fills.parquet
│ ├── evaluation_metrics.parquet
│ ├── data_quality.parquet
│ └── audit_log.parquet
├── models/
│ ├── gspqr_<train_date>.txt
│ └── registry.json
├── schemas/
│ └── registry.json
└── migrations/
├── 2026-10-10-initial.md
└── ...


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


# In the Dockerfile or run command
user: "99:100"
If a container needs a different UID, chown the target directory:
chown -R 1000:1000 /mnt/cache/quant/

But prefer running as 99:100. Mixing UIDs across containers leads to
permission confusion and silent write failures.
Docker Image Storage

On Unraid 7+, use the overlay2 storage driver with a ZFS volume for
Docker images. The legacy native driver has known stability issues on
ZFS pools.

    Settings → Docker → Docker image storage: ZFS

    Default appdata storage: /mnt/cache/appdata/

    Enable Docker custom networks: yes

    Host access to custom networks: enabled

    Custom network type: ipvlan (not macvlan)

Backup Script

Nightly at 18:00, rsync the cache pool to the array. This is a backup,
not a migration. Do not delete the source after.

#!/usr/bin/env bash
set -euo pipefail

SRC=/mnt/cache/quant/
DST=/mnt/user/quant-backup/

rsync -a --delete --exclude='*.tmp' "$SRC" "$DST"

# Log the result
DATE=$(date +%F)
echo "$DATE backup completed: $(du -sh "$DST" | cut -f1)" \
  >> /mnt/cache/appdata/quant/logs/backup.log

The array is slower, so the backup takes 10–30 minutes for a few GB.
Do not run it during market hours.
Snapshot Policy

ZFS on the cache pool supports snapshots. Configure a daily snapshot
retained for 14 days:

# Via Unraid's ZFS plugin or a User Script
zfs snapshot cache/quant@daily-$(date +%F)
zfs list -t snapshot -o name,creation cache/quant | \
  grep daily | head -n -14 | awk '{print $1}' | xargs -r -n1 zfs destroy

Snapshots are cheap. They catch the "I deleted a Parquet file at 3am"
scenario before the nightly backup can help.

# What Breaks on Unraid

Symptom	Cause	Fix
Parquet queries 100× slower after a night	Mover moved files to array	Set share mover action to Cache → Array, verify
Write failures "permission denied"	Container running as wrong UID	Set user: "99:100"
Docker stops working	docker.img full	Switch to ZFS image storage
Random kernel crashes	macvlan on bridge	Switch to ipvlan
GPU not detected	Unraid update broke driver	Regenerate CDI, pin Unraid version

# What Does Not Break on Unraid

The constitution, the schemas, the pipeline logic, the language boundaries,
the 5-day lock, the point-in-time rules. None of these are affected by
the host OS. If you find yourself changing one of them "for Unraid," you
are solving the wrong problem.