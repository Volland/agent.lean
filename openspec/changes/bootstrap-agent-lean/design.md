## Context

The repository is empty apart from tooling (tg, OpenSpec, ADR template); see proposal.md for motivation. The toolchain is Lean 4 (pinned; 4.35.0 at the time of writing). Lean compiles each module to C that includes only `lean.h`, but links a C++ runtime and the compiled `Init`/`Std` libraries, which ship prebuilt only for desktop hosts. Every design choice below is recorded as an ADR in `docs/adr/` and mirrored as a typed `Decision` section in `tg.md/decisions.md`; the external rules they respect are `Constraint` sections in `tg.md/constraints.md`.

## Goals / Non-Goals

**Goals:**
- One pure, provable agent core that behaves byte-for-byte the same on embedded Linux, iOS, Android and macOS.
- Guarantees that users get without writing proofs: termination, budgets, budget composition, policy-monitor soundness, codec round-trips, replay determinism.
- A footprint and overhead small enough for a phone app or a 64 MB board, enforced by CI budgets.

**Non-Goals:**
- RTOS/MCU and bare-metal targets (v2 track, via a pure-C mini-runtime).
- Runtime-registered or MCP tools (v2, as an untrusted tier).
- Graph/workflow orchestration, peer handoffs, long-running background agents.
- Token-level control of local inference (logit processors, speculative decoding).
- Long-term memory and retrieval inside the core: these are tools.
- Python, JS/WASM and Rust bindings (after v1).

## Decisions

### D1. Pure step machine (ADR 0002)
`step : State → Event → State × List Effect`. Effects: `llm`, `tool`, `emit` (UI), `complete`. Events: user input, model bytes/chunks, tool results, cancel, resume. Rejected: a Lean `IO` loop (not provable, binds the core to one networking stack); callbacks (thread registration and heap ownership problems). Motivated by the platform constraints on iOS processes and foreign threads.

### D2. Lean owns the wire format (ADR 0003)
Codecs for OpenAI-compatible Chat Completions (first) and Anthropic Messages (second) live in the core; the host transport is `send : Bytes → Stream Bytes`. Rejected: host-side provider SDKs (behaviour diverges, trust boundary leaks). Motivated by model output being untrusted.

### D3. In-process local adapter (ADR 0004)
`agent_llama.c` implements the transport over llama.cpp and accepts the same request bytes. Tool schemas derived by `deriving ToolSchema` become JSON-schema grammars for local decoding. Rejected: local server (no daemons on iOS); direct `llama.h` bindings (C++ in the core, single engine).

### D4. Runtime dependency budget (ADR 0005)
Runtime imports `Init` plus an allowlisted set of `Std` modules; `AgentLean.Meta` (deriving handlers, policy syntax, tactics) imports `Lean` and is never linked. Our own JSON and SSE codecs. Size budget in CI. GMP audit. Rejected: `Lean.Data.Json` (links the compiler).

### D5. Tools declared at compile time (ADR 0006)
`Tool` = input type, output type, optional pre/postcondition, executor `pure | io | host`, `idempotent : Bool` (required), labels `untrusted`, `sensitive`. The C ABI lets a host implement only declared host tools. Rejected: runtime registration (escapes policies).

### D6. Pull-based C ABI (ADR 0007)
Five functions; JSON payloads; single-thread-per-handle; `AgentLean.Driver` over libcurl for Lean users; Swift (module map, XCFramework), Android (JNI), KMP iOS (cinterop). Rejected: callbacks, generated bindings.

### D7. Generated C plus minimal runtime (ADR 0008)
`lake run bundle` emits a self-contained tree: generated C for `AgentLean` and the transitively needed `Init`/`Std` modules, pinned runtime sources, `lean.h`, the ABI shim, CMake and toolchain files. Runtime code uses no tasks or threads and keeps `Nat` out of data paths. A manifest lists every linked `lean_*` symbol. Rejected for v1: a pure-C runtime (planned v2 track).

### D8. Policies as monitors (ADR 0009)
Policy DSL: L1 guards over decoded arguments; L2 past-time temporal operators (`previously`, `since`, `count … ≤ n per turn`, taint predicates) compiled to automata whose state lives in `State`; L3 arbitrary `Prop` with proof or `Decidable`. Generic theorem: monitor verdict = formula over trace. Violations recoverable by default, `halt` per policy.

### D9. Event-sourced trace (ADR 0010)
State is the fold of `step` over the trace; snapshots are cached folds; theorem `resume (snapshot n) rest = replay all`. Context policy uses a byte-based token upper bound corrected by reported usage; pinned content always kept; oldest tool results elided first; summarization is an opt-in policy.

### D10. Credentials and untrusted data (ADR 0011)
`credential_ref` on model-request effects; `Secret` without serialization instances; sensitive payloads kept, traces flagged for host encryption, audit export hashes them.

## Risks / Trade-offs

- [Lean runtime does not cross-compile cleanly to iOS/Android] → Week-one spike (tasks group 1) before any other work; fall back to a reduced runtime if needed.
- [Static binary floor of `Init` + runtime is too large for the targets] → Spike measures it; tree-shaking per module and `--gc-sections`; the runtime-surface manifest scopes a pure-C runtime if needed.
- [Official toolchain links GMP (LGPL)] → Audit in the spike; build runtime with Lean's own bignum implementation for mobile.
- [Runtime ABI changes between Lean versions] → Exact toolchain pin; bundle regenerated and conformance-tested on every bump.
- [Provider APIs change] → Codecs are versioned modules covered by golden traces; OpenAI-compatible covers most endpoints.
- [Byte-based token estimate is too conservative and wastes context] → Correct with provider-reported usage; per-model ratio in config.
- [Policy DSL too weak for real rules] → L3 escape hatch; collect real policies from early users before extending L2.
- [Hand-written bindings drift from the ABI] → The same golden traces run through every binding in CI.

## Migration Plan

Not applicable: first change in a new repository. Rollback is reverting the change.

## Open Questions

- The numbers for the size, step-overhead, cold-start and memory budgets: set from the spike's measurements.
- Whether the official Lean release links GMP statically, dynamically or not at all on each platform: answered by the spike's audit.
- Which `Std` modules make the allowlist beyond `Std.Data.HashMap`: decided module by module as the core needs them.
