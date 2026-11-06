---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Pure step-machine core with host-executed effects

## Context and Problem Statement

agent.lean must run on embedded Linux, iOS and Android, and must let us prove properties of agents. Where should IO (HTTP, tools, storage, clocks) live, relative to the agent logic?

## Considered Options

* A pure transition function `step : State → Event → State × List Effect`; the host performs every effect and feeds results back as events
* A Lean `IO` loop that owns HTTP, tools and storage
* A core that calls host-registered callbacks

## Decision Outcome

Chosen option: "pure transition function", because pure code is what Lean proofs reason about directly, it makes replay deterministic for free, lets mobile hosts use their own networking stacks (URLSession, OkHttp), and confines a future port (RTOS/MCU) to the thin effect layer.

### Consequences

* Good, because invariants (termination, budgets, policies) are theorems about one function.
* Good, because the trace of events fully determines every state (see ADR 0010).
* Bad, because every host must run a driver loop; we mitigate with a Lean driver and thin bindings (ADR 0007).
* Bad, because streaming and parallelism need explicit events and call ids instead of plain control flow.

## More Information

Capability `openspec:agent-core`. Link code with `// @tg: implements:: [[adr:0002]]`.
