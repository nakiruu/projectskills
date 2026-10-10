---
name: ai-dev-workflow
description: Session conventions for Claude Code on this codebase.
  Load at the start of every session. Tells you which skills to read for
  which tasks, which MCP tools to use, how to verify work, and when to stop.
---

# AI Development Workflow

This skill is about *how* to work here, not *what* to build. It assumes
the constitution (`00-constitution`) has been read. If you have not read it
this session, read it before proceeding.

## 1. Session Start

Every session begins with the same four steps. Do not skip them because
the task "seems simple." The task that seems simple is the one that
violates an invariant.

1. **Read the constitution.** `.claude/skills/00-constitution/SKILL.md`.
   Ten invariants. You will not remember them from a previous session.

2. **Identify the layer.** Given the user's request, name the layer out loud
   in your first response: ingestion, panel, model, calibration, EVT, regime,
   conviction, portfolio, execution, frontend. If you cannot name it, ask.

3. **Load the layer skill.** Read the SKILL.md for that layer before writing
   code. Do not write code first and read the skill after.

4. **Run the session-start script.** `scripts/session-start.sh` checks that
   the Julia MCP is alive, DuckDB is reachable, and no invariant-violating
   files were modified in the last commit.

If any of the four fails, stop and report. Do not work around them.

## 2. Task Routing

Match the user's request to a skill. Read that skill before acting.

| User asks about...                              | Read skill         |
|-------------------------------------------------|--------------------|
| Downloading prices, SEC filings, FRED series    | 01-data-ingestion  |
| Computing features, ranks, forward returns      | 02-panel-construction |
| Training LightGBM, quantile regression          | 03-gspqr-model     |
| Conformal intervals, coverage, calibration      | 04-tcp-calibration |
| Tail bounds, GPD, extreme percentiles           | 05-evt-tails       |
| HMM, regime states, market state                | 06-regime-detection|
| F-Score, Altman Z, conviction, vetoes           | 07-fundamental-overlay |
| Weights, optimization, Sortino, covariance      | 08-portfolio-optimization |
| 5-day lock, position state, pending orders      | 09-lock-state-machine |
| Schwab API, order submission, fills             | 10-execution-schwab |
| Tokio, event bus, channels, async               | 11-rust-event-bus  |
| RustCall.jl, jlrs, Arrow IPC, FFI               | 12-julia-rust-bridge |
| Parquet files, DuckDB, schema, partitioning     | 13-parquet-lake    |
| Backtests, coverage, Winkler, CRPS              | 14-backtest-protocol |

If the request spans multiple layers, read all relevant skills. Do not
start with the one you know best.

## 3. Tool Selection

See `TOOL-ROUTING.md` for the full decision tree. The one-line summary:

- **Julia MCP** — for running Julia code, testing Julia analytics, exploring
  Julia packages. Never for editing files (use the editor).
- **DuckDB MCP** — for inspecting Parquet schemas, sampling rows, verifying
  data shape. Never for production queries (those live in code).
- **File tools** — for reading and editing source. Always prefer reading the
  actual file over assuming its contents.
- **Bash** — for running tests, builds, and git. Never for data manipulation
  that should be code.

Do not use the Julia MCP to write files. Do not use DuckDB to modify data.
Tools have jobs; keep them separate.

## 4. Code Generation Rules

Language-specific. Read the section for the language you are writing.

### Julia

- Prefer `DataFrames.jl` and `Arrow.jl` over raw arrays at module boundaries.
- Type-annotate function signatures for anything in `models/`, `portfolio/`,
  `regime/`, `conviction/`.
- Use `@views` for large array slices. Do not allocate copies by accident.
- Prefer `let` blocks over global variables. Nothing in these modules should
  be global mutable.
- Every public function has a docstring with Arguments, Returns, and an
  Example that actually runs.
- Tests use `Test.jl` with `@testset` per function.

### Rust

- No `unwrap()` outside of `main.rs` and test code. Use `?` and typed errors
  via `thiserror`.
- No `panic!` in library code. Panics are for unreachable states only, and
  even those should be `unreachable!()` with a comment.
- Lock states are types, not enums (see constitution §1).
- Async functions are annotated with their cancellation behavior. If a task
  can be cancelled mid-operation, the docs say so.
- Every public function has `///` docs with a `# Errors` section.
- Tests use `#[test]` for unit, `#[tokio::test]` for async.

### TypeScript / Bun

- `strict: true` in tsconfig. No `any` without a comment explaining why.
- Prefer `zod` schemas at API boundaries over hand-written validation.
- All async functions handle their own errors. No floating promises.
- React components (if any) are function components with explicit prop types.
- Tests use `bun test`.

## 5. Verification Protocol

Before claiming a task is complete, run `VERIFICATION.md`. It is a checklist,
not a suggestion. If any item fails, the task is not complete.

Minimum for any change:

- [ ] The relevant layer skill was read this session
- [ ] The change does not violate any constitution invariant
- [ ] A test exists for the new behavior
- [ ] The test passes locally
- [ ] If the change touches a Parquet schema, the schema hash is updated
- [ ] The change is committed with a message following `COMMIT-CONVENTIONS`

Do not say "done" until all six are true. If you cannot run a test because
the environment is broken, say so. Do not claim success you cannot verify.

## 6. When to Stop and Ask

Stop immediately and ask the user if any of these occur:

- A task requires changing a constitution invariant
- A task requires crossing a language boundary not documented in `12-julia-rust-bridge`
- A Parquet schema needs a non-additive change
- The user's request conflicts with a loaded skill
- You are about to write code that a linter or test would reject, and the
  "fix" is to weaken the linter or test
- You cannot identify which layer a task belongs to
- The user asks for something not covered by any skill

Do not improvise. The system has rules for a reason. A request that does not
fit the rules is a signal that either the rules or the request is wrong, and
the user decides which.

## 7. Anti-Patterns

See `ANTI-PATTERNS.md` for the full list. The three most common:

1. **Random train/test splits.** Every split in this codebase is
   chronological. If you write `train_test_split` without reading
   `14-backtest-protocol`, you will get it wrong.

2. **Using `period_end` instead of `filing_date`.** This is the most common
   point-in-time violation. The linter catches it in decision code, but if
   you are writing ingestion code, you might still be tempted. Do not.

3. **Adding a conviction component that duplicates a GSPQR feature.** If
   you are unsure whether a component is already in the 12-feature list,
   check `03-gspqr-model` before adding it.

## 8. Commits

Format:

    <layer>: <imperative summary>

    <body explaining what and why>

    Constitution: §N (if applicable)
    Skills: <skill-name> (if applicable)

Example:

    panel: add 126-day forward return target

    Adds y_fwd_126d to panel.parquet. Updates schema registry hash.
    No existing code depends on the new column yet.

    Constitution: §2, §5
    Skills: 02-panel-construction, 13-parquet-lake

Layer prefixes: `ingest`, `panel`, `gspqr`, `tcp`, `evt`, `regime`,
`conviction`, `portfolio`, `lock`, `exec`, `bus`, `ffi`, `parquet`,
`backtest`, `frontend`, `constitution`, `skills`, `docs`.

Commits that touch the constitution use `constitution:` and must update
`AMENDMENTS.md` in the same commit.

## 9. Responding to the User

- Lead with what you did, not what you are about to do.
- If you read a skill, name it. "Read `03-gspqr-model` before writing this."
- If a task failed a verification step, say which one. Do not soften it.
- If you are uncertain, say so with a specific question. "Should this go in
  panel or conviction?" is better than a guess.
- Do not summarize what the user already knows. They wrote the skills.

## 10. Limits

This skill does not tell you how to build the system. It tells you how to
work on it. For any specific layer, read that layer's skill. For the rules
that never change, read the constitution. For everything else, ask.

If you find yourself re-reading this file within a session, something above
is unclear. Propose an amendment to this skill in the same commit as whatever
work revealed the ambiguity.

## Unraid Deployment Conventions

This system runs on Unraid. The following conventions apply.

### Container Boundaries
- `quant-core`: Julia + Rust co-located. FFI in-process. Mounts cache pool.
- `quant-api`: Bun. Read-only access to Parquet. HTTP to quant-core.
- `duckdb`: optional query engine. Read-only.

### Storage Rules
- All live Parquet files live on the cache pool at `/mnt/cache/quant/`.
- Never write Parquet to the array (`/mnt/user/`). The array is for backup.
- Container state (logs, SQLite, locks) lives at `/mnt/cache/appdata/quant/`.

### Networking
- Docker custom network type: ipvlan, not macvlan.
- Wired connection only. Wireless requires Docker restart and reconfiguration.
- Host access to custom networks: enabled.

### Scheduling
- All scheduled jobs are Unraid User Scripts, not crontab.
- Scripts invoke `docker exec` against the relevant container.
- Never run long jobs directly on the host. Always inside a container.

### GPU
- If Nvidia-Driver plugin is installed, pass GPU UUID to quant-core.
- Pin Unraid version when GPU is in use. Version updates break driver compatibility.
- GPU is optional. LightGBM on CPU is fast enough for this workload.

### Debugging
- Container logs: `docker logs quant-core`
- Parquet inspection: DuckDB container or `duckdb` CLI on host
- Lock state: SQLite in `/mnt/cache/appdata/quant/locks.db`