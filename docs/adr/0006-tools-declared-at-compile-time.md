---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Tools are declared in Lean at compile time, with three executors

## Context and Problem Statement

Agents call pure computations, side-effecting Lean code, and platform features only the host app has (camera, contacts, GPIO). Policies and proofs need to know every tool an agent can call.

## Considered Options

* One `Tool` structure (input type, output type, pre/postcondition, executor `pure | io | host`), declared in Lean; hosts may only implement declared host tools
* Allow hosts to register tools at runtime through the C ABI
* Pure Lean tools only

## Decision Outcome

Chosen option: "declared in Lean, three executors", because a binding cannot introduce a tool the proofs and policies do not know about, while host features stay reachable. Every tool must declare `idempotent` (no default), and labels for `untrusted` output and `sensitive` data. Dynamic tools (MCP servers) are deferred to v2 as an explicitly untrusted tier that policies treat as opaque.

### Consequences

* Good, because the tool set is closed and every policy is checked against it.
* Bad, because adding a tool to a mobile app requires rebuilding the Lean part.
* Bad, because tool authors must answer "is this safe to retry?" up front, which is the point.

## More Information

Capability `openspec:tools`.
