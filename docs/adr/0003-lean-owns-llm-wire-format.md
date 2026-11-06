---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Lean owns the LLM wire format; the host is a byte transport

## Context and Problem Statement

Model requests and responses must be encoded and decoded somewhere. If every binding parses provider JSON itself, behaviour diverges per platform and the trust boundary moves outside the verified core.

## Considered Options

* Lean encodes requests and decodes responses (JSON and SSE); the host only does `send : Bytes → Stream Bytes`
* Hosts use native provider SDKs and pass parsed messages into Lean

## Decision Outcome

Chosen option: "Lean owns the wire format", because it keeps bindings tiny, makes every platform behave identically, and puts the decoding of untrusted model output under the same contracts as the rest of the core. v1 ships the OpenAI-compatible Chat Completions codec first (it covers OpenAI, llama-server, Ollama, vLLM, LM Studio, OpenRouter) and Anthropic Messages second.

### Consequences

* Good, because one golden-trace suite proves identical behaviour on all targets.
* Bad, because we maintain our own provider codecs and follow their API changes.

## More Information

Capability `openspec:llm-codecs`. The codecs depend on our own JSON/SSE parsers (ADR 0005).
