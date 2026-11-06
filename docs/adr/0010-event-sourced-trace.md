---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# The event-sourced trace is the source of truth

## Context and Problem Statement

Mobile operating systems kill apps mid-run, embedded boards lose power, and audits need to know exactly what an agent did. How is agent state persisted and recovered?

## Considered Options

* Event sourcing: the append-only trace of events is the truth, state is the fold of `step` over it, snapshots are an optimization
* Serialize mutable state only
* Leave persistence to each host

## Decision Outcome

Chosen option: "event sourcing", because with a pure `step` it gives deterministic replay and a provable resume (`resume snapshot rest = replay full`) at almost no cost. Storage itself is the host's job; the core produces and consumes versioned bytes. In-flight calls at crash time are re-issued only for idempotent tools. The context window is managed by a policy over the trace using a conservative token estimate; pinned content is never dropped, oldest tool results are elided first.

### Consequences

* Good, because every recorded session is also a regression test (golden traces).
* Bad, because traces grow; snapshots and audit export keep them manageable.

## More Information

Capabilities `openspec:trace-replay` and `openspec:agent-core`.
