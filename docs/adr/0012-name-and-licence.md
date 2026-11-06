---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Name, layout and Apache-2.0 licence

## Context and Problem Statement

The project needs stable names across Lean, C, Swift and Kotlin, and a licence compatible with Lean core and with static linking into commercial mobile apps.

## Considered Options

* Apache-2.0 (as Lean 4 and Mathlib)
* MIT
* LGPL or GPL

## Decision Outcome

Chosen option: "Apache-2.0", because it matches the Lean ecosystem and carries an explicit patent grant, and imposes no relinking obligations on apps. Names: project `agent.lean`, Lake package `agentLean`, namespace `AgentLean`, C prefix `agent_` in `agent.h`, Swift module `AgentLean`, Kotlin package `dev.agentlean`. Layout: `AgentLean/` (runtime), `AgentLean/Meta/` (compile-time), `c/`, `bindings/{swift,kotlin}`, `bundle/`, `traces/`.

### Consequences

* Good, because apps can embed the library without copyleft obligations.
* Bad, because LGPL dependencies such as GMP must stay out of default mobile builds (ADR 0005).
