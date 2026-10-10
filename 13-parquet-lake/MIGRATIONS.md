
---

## `MIGRATIONS.md`

```markdown
# Schema Migrations

The lake's schemas are frozen. This file describes how to change them
without breaking downstream consumers.

## The Rule

Additive only. New columns append to the right. No renames. No retypes.
No reorders. If you need a different shape, write a new file.

## When You Need a Migration

- Adding a column (common, easy)
- Adding a file (documented in `SCHEMAS.md`, no migration needed)
- Changing a writer's behavior (documented in the writer's skill)
- Deprecating a column (rare, requires a deprecation period)

## Adding a Column

Four steps, all in one commit:

**1. Update the writer.**

```julia
# Before
df = select(df, :ticker, :date, :q_50)

# After
df = select(df, :ticker, :date, :q_50, :q_60)  # new column appended
```

# 2. Add a migration file.

migrations/2026-11-02-add-q60-to-gspqr-predictions.md:
# Migration: add q_60 to gspqr_predictions

- Date: 2026-11-02
- Author: <name>
- Type: additive
- Affected file: gspqr_predictions.parquet

## Change

Appends column `q_60` (float64, nullable) to gspqr_predictions.
Contains the 60th-percentile prediction. Written by the same module.

## Rationale

The optimizer wants a slightly-above-median quantile for a variant
sizing rule. Existing median (`q_50`) is unchanged.

## Backfill

Not backfilled. `q_60` is null for dates before 2026-11-02. Consumers
must handle null.

## Downstream Impact

None. Adding a nullable column does not break readers that ignore it.

# 3. Regenerate the schema registry.
```julia
.claude/skills/13-parquet-lake/scripts/generate-registry.jl
```

# 4. Update SCHEMAS.md. Add the column to the table for that file.
Commit all four in one commit. CI verifies.

# Deprecating a Column

Rare. Requires a two-phase rollout:

## Phase 1 (soft deprecate). 
Mark the column as deprecated in SCHEMAS.md. Stop writing new values (write null). Keep the column in the schema for 90 days so readers do not break.

## Phase 2 (remove).
Only after 90 days with no reads. This requires a migration file and a PR that updates every reader.

Do not skip phase 1. A column that disappears overnight breaks every downstream consumer.

# Retyping a Column

Not supported in place. The procedure:

    Add a new column with the new type.

    Backfill from the old column.

    Update readers to use the new column.

    Deprecate the old column (90 days).

    Remove the old column.

Four migrations, spread over a quarter. If the change is urgent, the
problem is upstream — the original type was wrong. Consider whether
the fix is worth the disruption.

# Adding a File

Does not require a migration. Requires:

    Update SCHEMAS.md with the new file's schema.

    Update registry.json via the generate script.

    Update the writer's skill to reference the new file.

Commit all three.

# What Breaks Consumers
|Change|	Breaks readers?|
|-|-|
|Add nullable column|	No|
|Add non-nullable column|	Yes — readers get null errors|
|Remove column|	Yes|
|Rename column|	Yes|
|Retype column|	Yes, if narrowing|
|Reorder columns|	Yes, if position-based access|
|Change partitioning|	Yes, if path is hardcoded|
|Change compression|	No|
|Change file location|	Yes|

The safe zone is: add nullable columns and change compression. Everything
else requires consumer updates in the same commit.

# Verification
After any migration:

    □

    scripts/verify-schemas.sh passes
    □

    registry.json is regenerated
    □

    The migration file exists and is complete
    □

    SCHEMAS.md matches the actual file
    □

    A test reads back the file and asserts the new schema
    □

    No downstream consumer crashes on the new file
    □


