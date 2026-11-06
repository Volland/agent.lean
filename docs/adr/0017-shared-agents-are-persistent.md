---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Registered agents are persistent and handed to handles by the C shim

## Context and Problem Statement

Every handle refers to the same registered agents (tool definitions, policies). Lean reference counts of objects not marked as shared are not atomic, and the registry's `IO.Ref` is not safe to read from several threads at once. Driving distinct handles concurrently crashed in about 1 run in 7 (found by the Kotlin binding's stress test, reproduced in C).

## Considered Options

* Read the registry once at initialization, mark the agents persistent (never reference-counted) and pass them to every `agent_new`/`agent_restore` from the C shim
* Mark the agents multi-threaded (atomic reference counts)
* Serialize all native calls behind one process-wide lock in each binding

## Decision Outcome

Chosen option: "persistent and passed by the shim", because persistent objects cost nothing per access, nothing mutable is shared between handles afterwards, and bindings can lock per handle so agents run in parallel.

### Consequences

* Good, because 100 of 100 stress runs (4 threads, all golden traces) pass where 3 of 60 crashed before.
* Bad, because agents can only be registered during initialization; registering later would not be visible to handles (and was never supported).

## More Information

Capability `openspec:host-abi` (requirement "Handle thread confinement"). Implemented in `c/agent_abi.c` and `AgentLean/Abi.lean`; stress test `c/tests/threads_many.c`.
