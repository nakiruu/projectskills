---
name: julia-rust-bridge
description: FFI patterns between Julia and Rust. Load when touching
  RustCall.jl, jlrs, Arrow IPC exchange, or any cross-language boundary.
---

# Julia–Rust Bridge

The bridge is where Julia's analytics and Rust's execution meet. This
skill documents which direction to bridge, when, and with what data
format.

## 1. The Two Directions

| Direction | Tool | Use case |
|---|---|---|
| Julia calls Rust | **RustCall.jl** | Julia needs a hot-path function written in Rust |
| Rust calls Julia | **jlrs** | Rust needs Julia's analytics for a decision |

Both are used in this system, but for different purposes. See §3.

## 2. The Golden Rule: Do Not Bridge in the Hot Path

The system's hot path is the execution engine: order submission, lock
checks, risk gates. **This path must not cross the Julia boundary.**
Rust owns it end-to-end.

The Julia boundary is crossed only for:
- **Model training** (Julia-only, no Rust)
- **Model inference** (Rust calls Julia once per day for batch predictions)
- **Analytics** (Julia-only, no Rust)
- **One-off RPC** (Rust asks Julia for a specific prediction on demand)

If you are writing code that calls Julia from within an order submission
path, stop. The design is wrong. Move the Julia call earlier, cache the
result, and let Rust read the cache.

## 3. Direction Decision

**Julia calls Rust** when:
- A computation is on the critical path of a Julia pipeline
- The computation is not already a Julia function
- The Rust function has a simple scalar or array signature

Example: a fast GPD fitting routine in Rust called from `fit-tails.jl`.

**Rust calls Julia** when:
- Rust needs a prediction from the GSPQR model
- The call is infrequent (once per forecast cycle, not once per order)
- The latency budget allows a round-trip

Example: the daily inference job where Rust reads the panel, passes
feature vectors to Julia, and receives quantiles.

## 4. Data Exchange Format

See `ARROW-IPC.md`. The short version:

**For arrays and tables: Arrow IPC.** Zero-copy where possible. No JSON.
No CSV. No serialization round-trips through strings.

**For scalars: direct FFI.** `Int32`, `Int64`, `Float64`, `Bool`.
RustCall.jl handles the conversion automatically [citation:1].

**For structured records: Arrow IPC, not JSON.** JSON is for logs and
config, never for prediction outputs or feature matrices.

## 5. Memory Ownership

The most common source of FFI bugs is memory ownership confusion.

**Rule:** The language that allocates owns the deallocation, until it
explicitly transfers ownership. Transfers are explicit and documented.

RustCall.jl provides ownership types for this: `RustBox`, `RustRc`,
`RustArc`, `RustVec`, `RustSlice` [citation:3]. These map Rust's
ownership model to Julia's garbage collection.

**When passing arrays:**
- Rust allocates → Rust owns → Rust frees, or transfers ownership via
  `RustVec` to Julia
- Julia allocates → Julia owns → Julia frees, or Rust borrows for the
  duration of a call
- Never: Rust borrows a Julia array, then holds the pointer after the
  call returns

The `@rust` macro with explicit types ensures the borrow is scoped to
the call [citation:1].

## 6. Arrow IPC

See `ARROW-IPC.md`. The key facts:

- Arrow's C Data Interface enables zero-copy exchange between runtimes
  that support it [citation:8]
- Julia's Arrow.jl and Rust's arrow crate both support the IPC format
  [citation:8]
- Zero-copy is not guaranteed across all data types or schemas.
  Document the copy semantics for every exchange [citation:13]

## 7. Error Handling

**Rust errors must be surfaced in Julia, not swallowed.**

RustCall.jl maps Rust `Result` to Julia's error mechanism. Do not
unwrap in Rust code that crosses the boundary. Do not `@assert` in
Julia code that calls Rust. Use `RustCall.is_err` and `unwrap` [citation:3].

**Julia errors must be surfaced in Rust, not swallowed.**

jlrs propagates Julia exceptions as Rust errors. Do not use `try/catch`
in Rust code that calls Julia unless you are logging and re-raising.

## 8. What Not to Do

- Do not cross the boundary in the execution hot path.
- Do not use JSON for arrays or prediction outputs.
- Do not hold a Rust pointer to a Julia array after the call returns.
- Do not use `unwrap()` in Rust code that crosses the boundary.
- Do not use `@assert` in Julia code that calls Rust.
- Do not assume Arrow is zero-copy without verifying per data type.
- Do not call Julia from Rust in a tight loop. Batch the calls.
- Do not call Rust from Julia for something Julia can do in <1ms.

## 9. Verification

- [ ] A round-trip test passes on 100 rows: Julia prediction, Rust
      prediction, max difference < 1e-6
- [ ] A test asserts the Arrow schema matches on both sides
- [ ] A test asserts memory is freed (no leak) after 10,000 calls
- [ ] A test asserts errors propagate correctly in both directions
- [ ] No bridge call exists in the order submission path

## 10. Related Skills

- `03-gspqr-model` — the model export/load path
- `10-execution-schwab` — the Rust execution engine
- `11-rust-event-bus` — where bridge calls are scheduled
- `13-parquet-lake` — the shared data format