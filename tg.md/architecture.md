---
type: Concept
openspec: [agent-core, tools, policies, llm-codecs, trace-replay, host-abi, portable-build]
---
# Architecture

The vocabulary of agent.lean: a pure step machine in Lean that turns events into effects, with every effect performed by a host. Each term below is used with exactly this meaning in specs, ADRs and code.

```
Lean  : pure core (step, codecs, policies, proofs)
  ↓ C ABI (agent.h, JSON bytes, pull-based)
Host  : C driver · Lean driver · Swift · Kotlin — performs effects
```

## Step machine

The core's only behaviour: `step : State → Event → State × List Effect`. Deterministic, total, no IO. Capability `agent-core`.

## Event

Something the host feeds into the core: user input, model response bytes or stream chunks, a tool result, cancel, or resume. Every accepted event is appended to the trace.

## Effect

Something the core asks the host to do: a model request (`llm`), a tool call (`tool`), a display-only UI event (`emit`) or the end of a run (`complete`).

## Trace

The append-only list of events a run accepted, in arrival order. State is the fold of the step machine over it; a snapshot is a cached fold. Capability `trace-replay`.

## Transport

The host's byte pipe for model requests: `send : Bytes → Stream Bytes`. HTTP and the in-process local adapter are both transports, indistinguishable to the core. Capability `llm-codecs`.

## Codec

Pure Lean code that encodes model requests into a provider's wire format and decodes its responses and stream chunks into events. OpenAI-compatible first, Anthropic Messages second.

## Tool

A declared capability with an input type, an output type, optional contracts, an executor (`pure`, `io` or `host`), a required idempotency flag and data labels. Capability `tools`.

## Policy monitor

An automaton compiled from a policy formula over the trace, whose state lives in the agent state and which decides on each step whether a tool call is allowed. Capability `policies`.

## Host

The program that embeds the library: it drives the step machine through the C ABI or the Lean driver, performs effects and stores traces. Capability `host-abi`.

## Frame

One agent's part of a run: its history, pending calls, monitors and budget. Frame 0 is the root; a child agent started as a tool is a further frame whose effect ids carry the prefix `f<k>/`.

## Golden trace

A recorded run as lines `C <config>`, `E <event>`, `X <expected effect>` in `traces/`. Every target and binding replays them and must produce the same effects byte for byte.

## Source bundle

The self-contained tree of generated C, the needed Init/Std modules, the pinned runtime and the ABI shim that builds with stock toolchains. Capability `portable-build`.
