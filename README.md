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
  <img alt="Status: design" src="https://img.shields.io/badge/status-design%20phase-orange.svg">
  <img alt="Lean 4" src="https://img.shields.io/badge/Lean-4-6366f1.svg">
</p>

---

> **Status: design phase.** The architecture, decisions and specs are written down and reviewed; no library code exists yet. The first milestone is a one-week **feasibility spike** that cross-compiles a hello-agent to iOS, Android and aarch64 Linux and measures size and start-up. See [the bootstrap change](openspec/changes/bootstrap-agent-lean/).

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

## A taste (API sketch, subject to change)

```lean
import AgentLean
open AgentLean

structure Transfer where
  to     : String
  amount : UInt32
deriving ToolSchema

def transfer : Tool Transfer Receipt where
  name       := "transfer"
  executor   := .host "bank.transfer"   -- implemented by the iOS/Android app
  idempotent := false                   -- required: never auto-retried after a crash
  sensitive  := true
  pre        := fun t => t.amount ≤ 100

policy confirmBeforePay :=
  call "transfer" → previously (call "confirm_user") since userTurn

def payAgent : Agent where
  system   := "You help the user pay their friends."
  tools    := [transfer, confirmUser]
  policies := [confirmBeforePay]
  budget   := { steps := 20, toolCalls := 8, tokens := 32_000 }
```

Driving it from C (any host works the same way):

```c
agent_t *a = agent_new(config, config_len);
agent_feed(a, user_msg, user_msg_len);
agent_buf_t eff;
while (agent_next_effect(a, &eff)) {
    /* llm  → POST bytes through your transport, feed the response back
       tool → run the host tool, feed the result back
       emit → update the UI
       complete → done */
}
agent_free(a);
```

## Targets

| Class | Targets |
|---|---|
| Embedded Linux | aarch64, armv7, riscv64, x86_64 (static, musl) |
| Mobile | iOS arm64 + simulator (XCFramework, Swift), Android arm64-v8a + x86_64 (AAR, Kotlin/JNI) |
| Desktop | macOS, Linux |
| Later | RTOS/MCU via a pure-C mini-runtime (v2 track) |

Bindings are hand-written over each platform's native FFI (Swift C interop, JNI, Kotlin/Native cinterop) and pass the same golden-trace conformance suite as the C ABI.

## Small and fast, measured

The runtime library imports only Lean's `Init` and an allowlist of `Std` modules (never `import Lean`), ships its own JSON and SSE codecs, uses no threads, and records every Lean runtime symbol it links. CI will fail on regressions in:

- binary size of a stripped static reference agent
- step overhead, codec throughput, cold start and memory per agent

The budget numbers will be set from the feasibility spike's measurements rather than guessed.

## Roadmap

1. **Feasibility spike**: hello-agent on iOS, Android, aarch64 Linux; size and start-up floors; GMP licence audit.
2. Skeleton, import and `sorry` guards, CI.
3. JSON/SSE codecs with proofs.
4. Agent core, tools, policies.
5. LLM codecs, trace and replay.
6. C ABI, Lean driver, local llama.cpp adapter.
7. Source bundle, target matrix, budgets.
8. Swift and Kotlin bindings.

The full task list is in [tasks.md](openspec/changes/bootstrap-agent-lean/tasks.md).

## Design documents

- **Architecture decisions**: [docs/adr/](docs/adr/) (ADRs 0002–0012)
- **Specs**: [openspec/changes/bootstrap-agent-lean/specs/](openspec/changes/bootstrap-agent-lean/specs/), one per capability: `agent-core`, `tools`, `policies`, `llm-codecs`, `trace-replay`, `host-abi`, `portable-build`
- **Design**: [design.md](openspec/changes/bootstrap-agent-lean/design.md)
- **Typed knowledge graph**: [tg.md/](tg.md/) holds concepts, decisions and constraints as a typed graph, checked with the `tg` CLI

## Out of scope for v1

Runtime-registered or MCP tools, graph/workflow orchestration, token-level control of local inference, long-term memory inside the core (build it as tools), and Python/JS/Rust bindings.

## Licence

[Apache-2.0](LICENSE).

## Meet Lemma

Lemma is a small chip that only does what it can prove. Its antenna listens to the model; the check on its chest is the proof.
