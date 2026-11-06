---
type: Decision
specs: ["adr:0002", "adr:0003", "adr:0004", "adr:0005", "adr:0006", "adr:0007", "adr:0008", "adr:0009", "adr:0010", "adr:0011", "adr:0012", "adr:0013", "adr:0014", "adr:0015", "adr:0016", "adr:0017"]
openspec: [agent-core, tools, policies, llm-codecs, trace-replay, host-abi, portable-build]
---
# Decisions

The design choices of agent.lean, one section per ADR in `docs/adr/`, with what motivates each as typed edges. The ADR holds the alternatives; this file holds the relations.

ADRs 0002–0012 come from the design session, 0013–0017 from the implementation.

## Pure step machine core

The core is `step : State → Event → State × List Effect` with no IO; hosts perform every effect. ADR 0002.

- motivated_by:: [[architecture#Step machine]] {weight: primary}
- motivated_by:: [[constraints#Foreign threads must register with the Lean runtime]] {weight: secondary}
- motivated_by:: [[constraints#iOS forbids background daemons]] {weight: secondary}

## Lean owns the LLM wire format

Request encoding and response and stream decoding live in Lean; the host transport only moves bytes. OpenAI-compatible first, Anthropic Messages second. ADR 0003.

- motivated_by:: [[constraints#Model output is untrusted]] {weight: primary}
- motivated_by:: [[architecture#Codec]] {weight: secondary}
- motivated_by:: [[decisions#Pure step machine core]] {weight: secondary}

## Local inference via in-process adapter

Local models run through an in-process transport adapter over llama.cpp that the core cannot tell from remote; derived tool schemas become decoding grammars. ADR 0004.

- motivated_by:: [[constraints#iOS forbids background daemons]] {weight: primary}
- motivated_by:: [[architecture#Transport]] {weight: secondary}
- motivated_by:: [[decisions#Lean owns the LLM wire format]] {weight: secondary}

## Runtime dependency budget

Runtime code imports only Init and allowlisted Std modules, uses its own JSON and SSE codecs, stays within a CI size budget and avoids GMP on mobile. ADR 0005.

- motivated_by:: [[constraints#Importing Lean links the compiler]] {weight: primary}
- motivated_by:: [[constraints#Embedded memory and flash are scarce]] {weight: primary}
- motivated_by:: [[constraints#GMP is LGPL]] {weight: secondary}

## Tools declared at compile time

Every tool is declared in Lean with types, contracts, an executor (pure, io, host), a required idempotency flag and data labels; hosts cannot add tools. ADR 0006.

- motivated_by:: [[architecture#Tool]] {weight: primary}
- motivated_by:: [[constraints#Model output is untrusted]] {weight: primary}
- motivated_by:: [[decisions#Policies compiled to monitors]] {weight: secondary}

## Pull-based C ABI

Hosts drive agents through five C functions with JSON payloads and never receive callbacks; Lean users get a libcurl driver; Swift and Kotlin bind through native FFI. ADR 0007.

- motivated_by:: [[constraints#Foreign threads must register with the Lean runtime]] {weight: primary}
- motivated_by:: [[constraints#Lean has no HTTP or TLS client]] {weight: secondary}
- motivated_by:: [[constraints#Android has no Panama FFM]] {weight: secondary}
- motivated_by:: [[architecture#Host]] {weight: secondary}

## Generated C plus minimal runtime

v1 ships generated C with the pinned Lean runtime as a self-contained bundle, uses no threads, records every runtime symbol, and plans a pure-C runtime for v2. ADR 0008.

- motivated_by:: [[constraints#Lean runtime is C++]] {weight: primary}
- motivated_by:: [[constraints#No prebuilt Lean libraries for mobile and embedded]] {weight: primary}
- motivated_by:: [[constraints#Lean runtime ABI is not stable]] {weight: secondary}
- motivated_by:: [[architecture#Source bundle]] {weight: secondary}

## Policies compiled to monitors

Per-call guards and past-time temporal policies are compiled to monitors with a soundness theorem; violations return a refusal to the model unless marked halt. ADR 0009.

- motivated_by:: [[architecture#Policy monitor]] {weight: primary}
- motivated_by:: [[constraints#Model output is untrusted]] {weight: primary}
- motivated_by:: [[decisions#Event-sourced trace]] {weight: secondary}

## Event-sourced trace

The append-only trace is the source of truth; state is its fold, snapshots are cached folds, and resume equals full replay. The context window is a policy over it. ADR 0010.

- motivated_by:: [[architecture#Trace]] {weight: primary}
- motivated_by:: [[constraints#Mobile operating systems terminate apps]] {weight: primary}
- motivated_by:: [[decisions#Pure step machine core]] {weight: secondary}

## Credentials by reference

Model requests name credentials by reference and secrets cannot be serialized; sensitive tool output is kept for replay, encrypted by the host and hashed on export. ADR 0011.

- motivated_by:: [[constraints#Model output is untrusted]] {weight: primary}
- motivated_by:: [[decisions#Event-sourced trace]] {weight: secondary}

## Apache-2.0 licence and naming

The project is Apache-2.0, named agent.lean, with Lake package `agentLean`, namespace `AgentLean` and C prefix `agent_`. ADR 0012.

- motivated_by:: [[constraints#GMP is LGPL]] {weight: secondary}

## Feasibility spike passed

The week-one spike cross-compiled a hello-agent to macOS, Mac Catalyst, iOS, Android and Linux on four architectures (0.5–1.2 MB static), so the design stands. Recorded with ADR 0008.

- motivated_by:: [[constraints#No prebuilt Lean libraries for mobile and embedded]] {weight: primary}
- motivated_by:: [[decisions#Generated C plus minimal runtime]] {weight: primary}

## Runtime without libuv

The bundled runtime drops libuv, OpenSSL, GMP and mimalloc; a POSIX shim stands in for the few libuv calls `io.cpp` makes, and runtime patches must apply exactly. ADR 0013.

- motivated_by:: [[constraints#The Lean runtime core calls libuv]] {weight: primary}
- motivated_by:: [[constraints#GMP is LGPL]] {weight: secondary}
- motivated_by:: [[constraints#iOS has no system call]] {weight: secondary}
- motivated_by:: [[decisions#Runtime dependency budget]] {weight: secondary}

## Flat frames for agent-as-tool

Child agents run as frames in one flat array with `f<k>/` id prefixes; budgets are reserved at spawn and returned at the end. ADR 0014.

- motivated_by:: [[architecture#Frame]] {weight: primary}
- motivated_by:: [[decisions#Event-sourced trace]] {weight: secondary}

## Golden traces as the conformance contract

Line-based golden traces (config, events, expected effects) are replayed through every ABI and binding and must match byte for byte. ADR 0015.

- motivated_by:: [[architecture#Golden trace]] {weight: primary}
- motivated_by:: [[decisions#Event-sourced trace]] {weight: secondary}

## Driver loads libcurl at run time

The Lean driver resolves libcurl with `dlopen` at first use, so no curl headers or link flags are needed anywhere. ADR 0016.

- motivated_by:: [[constraints#Lean's bundled linker cannot read current macOS SDK stubs]] {weight: primary}
- motivated_by:: [[constraints#Lean has no HTTP or TLS client]] {weight: secondary}

## Registered agents are persistent

The C shim reads the registered agents once, marks them persistent and passes them to every new handle, so concurrent handles share nothing mutable. ADR 0017.

- motivated_by:: [[constraints#Lean reference counts are not atomic by default]] {weight: primary}
- motivated_by:: [[decisions#Pull-based C ABI]] {weight: secondary}
