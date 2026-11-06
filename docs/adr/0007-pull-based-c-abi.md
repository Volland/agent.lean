---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Pull-based C ABI with JSON payloads, a Lean driver and native-FFI bindings

## Context and Problem Statement

Hosts in C, Swift, Kotlin and Lean must drive agents. The Lean runtime requires foreign threads to be registered, and callbacks across its reference-counted heap are error-prone.

## Considered Options

* Pull API: `agent_new`, `agent_feed`, `agent_next_effect`, `agent_snapshot`, `agent_free`; the host runs the loop
* Callback API: the host registers functions the core calls
* Generated bindings (SWIG, UniFFI)

## Decision Outcome

Chosen option: "pull API", because the library never calls host code or starts threads, so it fits Swift concurrency, the JVM and bare C alike. One handle is used by one thread at a time. Payloads are JSON bytes using our codec. Lean users get `AgentLean.Driver`, an IO loop over libcurl (Lean has no HTTP/TLS client). Swift binds through a module map in an XCFramework, Android through JNI, Kotlin Multiplatform iOS through cinterop, all hand-written over the native FFI.

### Consequences

* Good, because every binding is a thin, idiomatic wrapper over five functions.
* Bad, because hosts write (or reuse) a driver loop and run parallel tool calls themselves.

## More Information

Capability `openspec:host-abi`.
