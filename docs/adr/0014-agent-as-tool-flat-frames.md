---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Agent-as-tool runs as flat frames addressed by id prefixes

## Context and Problem Statement

A child agent started as a tool needs its own history, pending calls, monitors and budget inside the parent's state, and its effects must reach the host and its results come back.

## Considered Options

* A flat array of frames in one `Run`; frame 0 is the root, a child records its parent and call; ids of child effects carry the prefix `f<k>/`
* A recursive state (each frame holds its children)
* Child agents as separate host-level handles

## Decision Outcome

Chosen option: "flat frames", because the state stays non-recursive (derived JSON snapshots, simple proofs), the host routes results without knowing about frames, and budgets compose by reservation: a child gets `min(own budget, parent's remaining)` reserved at spawn and returned at its end, so parallel children cannot overrun the parent together (`allocate_le`).

### Consequences

* Good, because snapshots, replay and policies work unchanged for nested agents.
* Bad, because ids grow a prefix per level of nesting.

## More Information

Capability `openspec:agent-core` (requirement "Agent as tool").
