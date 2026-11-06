## Why

Agent frameworks today are big runtimes (Python, Node) that cannot ship inside a phone app or a 64 MB router, and none of them can *prove* anything about what an agent will do: tool-ordering rules live in prompts. agent.cpp and agent.rs showed that a small native agent library is useful; agent.lean takes the same idea to Lean 4, which compiles to C and lets the rules an agent must follow be stated as theorems and enforced by construction.

## What Changes

- New Lean 4 library `agentLean` (namespace `AgentLean`) whose core is a **pure step machine**: `step : State → Event → State × List Effect`. The host performs all IO.
- **Verifiability** as the product's identity: typed tool boundaries, library-proven invariants (termination, budgets, budget composition), runtime contracts as `Decidable` props, a temporal **policy DSL** compiled to monitors with a soundness theorem, and **deterministic replay** of an event-sourced trace.
- **LLM codecs owned by Lean**: OpenAI-compatible Chat Completions first, Anthropic Messages second, incremental SSE streaming; hosts only move bytes.
- **Local inference** through an in-process transport adapter (llama.cpp) that the core cannot tell apart from a remote endpoint; tool schemas derived from Lean types become decoding grammars.
- **Tools** with three executors (`pure`, `io`, `host`), all declared in Lean at compile time, each with a required idempotency flag and taint/sensitivity labels.
- A **pull-based C ABI** (`agent.h`) with JSON payloads, a Lean-native driver over libcurl, and Swift and Kotlin bindings built on each platform's native FFI.
- A **portable source bundle**: generated C plus a minimal Lean runtime, cross-compiled for embedded Linux (aarch64, armv7, riscv64, x86_64), iOS and Android, with CI budgets for size, speed and runtime surface.
- Licence Apache-2.0.

## Capabilities

### New Capabilities

- `agent-core`: the pure step machine: ReAct loop, budgets, parallel tool calls, UI events, agent-as-tool and context-window policy.
- `tools`: typed tool declaration, schema derivation, executors, contracts, idempotency and data labels.
- `policies`: per-call guards and temporal trace policies, their monitors and how violations are handled.
- `llm-codecs`: provider wire formats, streaming decoding, transport neutrality and local constrained decoding.
- `trace-replay`: the event-sourced trace, deterministic replay, snapshots, resume and audit export.
- `host-abi`: the C ABI, threading contract, credential handling, the Lean driver and native bindings.
- `portable-build`: the source bundle, target matrix and the CI budgets that keep the library small, fast and proven.

### Modified Capabilities

(none: this is the first change in the project)

## Impact

- **New code**: `AgentLean/` (runtime), `AgentLean/Meta/` (compile-time only), `c/` (ABI shim, reference driver, `agent_llama.c`), `bindings/swift`, `bindings/kotlin`, `bundle/` (CMake and toolchains), `traces/` (golden traces).
- **Dependencies**: a pinned Lean 4 toolchain; libcurl (Lean driver, Linux); llama.cpp (optional local adapter); Xcode and the Android NDK for mobile builds. No `import Lean` at runtime.
- **lat.md sections**: new `tg.md/architecture.md` (Concept), `tg.md/decisions.md` (Decision), `tg.md/constraints.md` (Constraint); `tg.md/tg.md` index updated.
- **Binding decisions and constraints**: ADRs 0002–0012 in `docs/adr/`; constraints recorded in `tg.md/constraints.md` (the Lean runtime is C++, there are no prebuilt Lean libraries for mobile, LGPL obligations of GMP, iOS process limits, Android JNI, untrusted model output).
- **Requirements added**: every requirement in `[[openspec:agent-core]]`, `[[openspec:tools]]`, `[[openspec:policies]]`, `[[openspec:llm-codecs]]`, `[[openspec:trace-replay]]`, `[[openspec:host-abi]]` and `[[openspec:portable-build]]`.
- **Risk gate**: the week-one feasibility spike (task group 1) decides whether the Lean runtime can be cross-compiled to iOS and Android within an acceptable size; everything else depends on it.
