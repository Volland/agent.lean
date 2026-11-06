---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Local inference through an in-process transport adapter

## Context and Problem Statement

v1 must run models on-device (embedded boards, phones) as well as remote APIs. iOS cannot run background daemons, and binding an inference engine into the core would pull C++ and one engine's API into it.

## Considered Options

* A local server (`llama-server`, Ollama) on localhost
* An in-process adapter (`agent_llama.c`, linking llama.cpp) that implements the same transport interface and speaks the same request/response bytes
* Lean bindings to `llama.h` with token-level control

## Decision Outcome

Chosen option: "in-process transparent adapter", because the core cannot tell local from remote, the core stays free of C++ and of any one engine, and mobile hosts can plug MLX, Core ML or MediaPipe in the same way. Tool input schemas are derived from Lean types (`deriving ToolSchema`); remote providers receive them as tool schemas and the local adapter turns them into decoding grammars, so small local models cannot emit malformed tool arguments.

### Consequences

* Good, because transport neutrality is testable: the same trace must result from both transports.
* Bad, because token-level control (logit processors, speculative decoding) is out of reach until a later extension.

## More Information

Capabilities `openspec:llm-codecs` and `openspec:tools`.
