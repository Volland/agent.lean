---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Temporal policy DSL compiled to monitors, violations recoverable by default

## Context and Problem Statement

The headline promise is that rules about which tools an agent may call, and in what order, are theorems rather than prompts. How expressive is the policy language, and what happens on a violation?

## Considered Options

* L1 per-call guards plus L2 past-time temporal formulas over the trace, compiled to monitor automata, with L3 arbitrary `Prop`s as an escape hatch
* Arbitrary `Prop`s only, proved or decided by the user
* Guards only

## Decision Outcome

Chosen option: "L1 + L2 DSL compiled to monitors, L3 escape hatch", because past-time temporal properties over finite traces are decidable and monitorable at constant cost per step, and one generic theorem (the monitor accepts exactly the traces satisfying the formula) gives every user policy a guarantee without user proofs. Violations are recoverable by default (a refusal naming the policy goes back to the model and into the trace); a policy can be marked `halt`. Taint labels from tools let policies express information-flow rules against prompt injection.

### Consequences

* Good, because users write declarative policies and get proofs for free.
* Bad, because properties outside past-time logic need L3 and a user proof or a runtime check.

## More Information

Capability `openspec:policies`.
