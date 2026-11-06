<p align="center">
  <img src="assets/mascot.svg" width="160" alt="Lemma, the agent.lean mascot: a small microchip robot with a proof checkmark">
</p>

<h1 align="center">agent.lean</h1>

<p align="center">
  <b>A tiny, verifiable agent library in Lean 4 that compiles to C.</b><br>
  Write LLM agents with tools in Lean, prove what they may do, and ship them to phones and embedded boards.
</p>

<p align="center">
  <a href="LICENSE"><img alt="License: Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue.svg"></a>
  <a href="https://github.com/Volland/agent.lean/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Volland/agent.lean/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="Status: v0.1" src="https://img.shields.io/badge/status-v0.1%20preview-orange.svg">
  <img alt="Lean 4" src="https://img.shields.io/badge/Lean-4-6366f1.svg">
</p>

---

> **Status: v0.1 preview.** The core, codecs, policies, trace, C ABI, Lean driver, bundle, Swift and Kotlin bindings and the llama.cpp adapter are implemented; the guarantees below are proved in Lean or checked by tests. APIs may still change.

## Why

agent.cpp and agent.rs showed that an agent framework can be a small native library instead of a Python runtime. agent.lean takes that idea to Lean 4, which gives two things the others can't:

- **Proofs about agents.** Rules such as *"`send_payment` only after `confirm_user` in the same turn"* or *"at most 3 web fetches per turn"* are **theorems enforced by construction**, not instructions in a prompt.
- **Portable C output.** Lean compiles to C, so the same agent runs on a Raspberry Pi, an industrial gateway, an iPhone or an Android phone, with no interpreter and no garbage-collected VM.

## How it works

```
┌──────────────────────── Lean (pure, proven) ────────────────────────┐
│  step : State → Event → State × List Effect                         │
│  codecs (OpenAI-compatible, Anthropic) · tools · policy monitors    │
└───────────────▲──────────────────────────────────────┬──────────────┘
         events │  (JSON bytes over the C ABI agent.h) │ effects
┌───────────────┴──────────────────────────────────────▼──────────────┐
│  Host: C driver · Lean driver (libcurl) · Swift · Kotlin            │
│  runs HTTP or the in-process local model, executes host tools,      │
│  stores the trace, holds the API keys                               │
└─────────────────────────────────────────────────────────────────────┘
```

- **Pure core.** The whole agent is one deterministic function from state and event to new state and effects. The core performs no IO, so it can be proved about, replayed exactly and embedded anywhere.
- **Host does the IO.** Phones use their own networking (URLSession, OkHttp), boards use libcurl. The host only moves bytes; Lean encodes and decodes the provider formats, so every platform behaves the same.
- **Remote and local models.** OpenAI-compatible endpoints (OpenAI, Ollama, llama-server, vLLM, LM Studio, OpenRouter) and Anthropic Messages. Local models run in-process through a llama.cpp adapter that the core cannot tell apart from a remote API.
- **Event-sourced.** Every event is appended to a trace. State is a fold over it, resume after the OS kills your app is exact, and every recorded session is a regression test.

## What is guaranteed

| Guarantee | How |
|---|---|
| Tools never see malformed input | Arguments are decoded into the tool's Lean type or rejected; JSON Schema is derived from the type |
| Small local models emit valid tool calls | The derived schema becomes a decoding grammar in the local adapter |
| Every run terminates within its budgets | Theorem over `step`; sub-agents cannot exceed their parent's remaining budget |
| Your policies hold | Temporal policies compile to monitors with a soundness theorem; violations are refused before any effect |
| Prompt injection cannot trigger guarded actions | Tools label output as untrusted; policies can forbid actions after untrusted input unless confirmed |
| Replay is exact | `resume snapshot rest = replay full trace`, proved |
| API keys never reach traces | Requests carry a credential *reference*; a `Secret` cannot be serialized |
| Codecs are correct | Round-trip and chunk-split theorems for the JSON and SSE parsers |

## Quick start

```bash
lake build                 # the library (Lean 4.35, pinned in lean-toolchain)
lake test                  # 43 scenario tests, one per spec scenario
scripts/check_proofs.sh    # no sorry; main theorems use only Lean's standard axioms

# run the example assistant through the Lean driver against any OpenAI-compatible endpoint
lake build driver_demo
AGENT_CREDENTIAL_OPENAI=$OPENAI_API_KEY .lake/build/bin/driver_demo \
  --endpoint https://api.openai.com/v1/chat/completions --model gpt-4.1-mini "What is 17 plus 25?"
# or a local model: --endpoint http://127.0.0.1:11434/v1/chat/completions --model <ollama model>

# the portable source bundle: plain C/C++ + CMake, no Lean needed to build it
python3 scripts/bundle.py --root Examples --out bundle/out --extra c/agent_abi.c --extra-include c/agent.h
```

Write an agent:

```lean
import AgentLean
meta import AgentLean.Meta     -- deriving handlers and `policy`, compile time only
open AgentLean AgentLean.Formula

structure TransferArgs where
  to     : String
  amount : UInt32
  memo   : Option String
  deriving ToJson, FromJson, ToolSchema   -- JSON Schema derived from the type

def transfer : Tool TransferArgs Receipt where
  name       := "transfer"
  description := "Send money to a contact"
  executor   := .host "bank.transfer"     -- implemented by the iOS/Android app
  idempotent := false                     -- required: never re-issued after a crash
  sensitive  := true                      -- trace flagged for encryption, hashed on audit export
  pre x      := x.amount > 0

policy payLimit := guard "transfer" "amount ≤ 100" (argNat "amount" (· ≤ 100))
  because "transfers above 100 need a human"
policy confirmBeforePay := requiresBefore "transfer" "confirm_user"
policy noDelete halt := ¬ₚ call! "delete_all"

def assistant : Agent where
  name     := "assistant"
  system   := "You are a careful assistant."
  tools    := #[transfer.erase, confirmUser.erase, Agent.asTool "researcher" "research" "Delegate research"]
  policies := #[payLimit, confirmBeforePay, noDelete]
  budget   := { steps := 64, toolCalls := 10, tokens := 100000 }

initialize registerAgent assistant
```

See [Examples/Agents.lean](Examples/Agents.lean) for the full example.

Drive it from C (Swift, Kotlin and the Lean driver wrap the same five calls):

```c
agent_t *a = agent_new(cfg, cfg_len, NULL);   /* {"agent":"assistant","model":...,"endpoint":...} */
agent_feed(a, user_event, len);
agent_buf_t e;
while (agent_next_effect(a, &e)) {
    /* llm_request → POST e.body to e.url, adding the secret named by e.credential; feed llm_response
       tool_call   → run the host tool; feed tool_result
       ui          → update the UI
       complete    → done */
    agent_buf_free(e);
}
agent_free(a);
```

## Proved and tested

| Guarantee | Where |
|---|---|
| Policy monitors decide exactly what the formula says over the whole trace | `monitor_sound` ([Policy.lean](AgentLean/Policy.lean)) |
| Every run ends within its step budget; a finished run does nothing | `final_done`, `done_sticky` ([Run.lean](AgentLean/Run.lean)) |
| A child agent never gets more than its parent has left | `allocate_le` |
| Resuming from a snapshot gives the same states and effects as replaying everything | `stepAll_append` ([Trace.lean](AgentLean/Trace.lean)) |
| SSE decoding is independent of how the stream is split | `Sse.feed_chunks` |
| Requests fit the context estimate; system prompt and last user turn are never dropped | `fit_fits`, `fit_head`, `fit_keeps_last_turn` |
| Tool arguments decode into the tool's type or are rejected; schema acceptance = decoding | scenario tests |
| Same behaviour byte for byte on every target and binding | golden traces in [traces/](traces/) |

## Measured (v0.1, Apple M-series / Docker)

| Target | Reference agent, stripped | Notes |
|---|---|---|
| macOS arm64 | 0.97 MB | step ≈ 40 µs, codec ≈ 80 MB/s, cold start < 1 ms, ≈ 7 KB per idle agent |
| Linux aarch64 (static musl) | 1.7 MB | includes musl and libc++; step ≈ 55 µs |
| Linux x86_64 / armv7 / riscv64 (static musl, emulated) | 1.66 / 1.41 / 1.31 MB | conformance + thread tests pass under QEMU |
| iOS arm64, Android arm64-v8a / x86_64 | builds | golden traces pass on the Android emulator (CI) and as Mac Catalyst; iOS device not run |

Budgets live in [bench/budgets.json](bench/budgets.json) and [bundle/runtime-surface/](bundle/runtime-surface/); CI fails on regressions.

## Targets

| Class | Targets |
|---|---|
| Embedded Linux | aarch64, armv7, riscv64, x86_64 (static, musl) |
| Mobile | iOS arm64 + simulator (XCFramework, Swift), Android arm64-v8a + x86_64 (AAR, Kotlin/JNI) |
| Desktop | macOS, Linux |
| Later | RTOS/MCU via a pure-C mini-runtime (v2 track) |

Bindings are hand-written over each platform's native FFI (Swift C interop, JNI, Kotlin/Native cinterop) and pass the same golden-trace conformance suite as the C ABI.

## Layout

| Path | What |
|---|---|
| `AgentLean/` | the runtime library (imports only `Init`) |
| `AgentLean/Meta/` | compile-time deriving handlers and the `policy` command |
| `AgentLean/Driver.lean`, `c/agent_curl.c` | the Lean-native driver (libcurl, loaded at run time) |
| `c/agent.h`, `c/agent_abi.c` | the C ABI |
| `c/llama/` | in-process llama.cpp adapter (grammar-constrained tool calls) |
| `bindings/swift`, `bindings/kotlin` | Swift (XCFramework/SwiftPM) and Kotlin (JNI/AAR) bindings |
| `scripts/bundle.py`, `bundle/` | the portable source bundle generator and runtime shim |
| `traces/` | golden traces every target must reproduce |
| `Tests/` | scenario tests, golden generator, axiom report |

## Roadmap

v0.1 (this): everything in the [bootstrap change](openspec/specs/). Next: a pure-C mini-runtime implementing the recorded runtime surface (RTOS/MCU targets), optional vendored mimalloc, MCP as an untrusted dynamic tool tier, streaming in the local adapter.

## Design documents

- **Architecture decisions**: [docs/adr/](docs/adr/) (ADRs 0002–0017)
- **Specs**: [openspec/specs/](openspec/specs/), one per capability: `agent-core`, `tools`, `policies`, `llm-codecs`, `trace-replay`, `host-abi`, `portable-build`
- **Design**: [design.md](openspec/changes/archive/) of the archived bootstrap change
- **Typed knowledge graph**: [tg.md/](tg.md/) holds concepts, decisions and constraints as a typed graph, checked with the `tg` CLI

## Out of scope for v1

Runtime-registered or MCP tools, graph/workflow orchestration, token-level control of local inference, long-term memory inside the core (build it as tools), and Python/JS/Rust bindings.

## Licence

[Apache-2.0](LICENSE).

## Meet Lemma

Lemma is a small chip that only does what it can prove. Its antenna listens to the model; the check on its chest is the proof.
