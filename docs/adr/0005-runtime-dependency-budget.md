---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Runtime dependency budget: Init plus a Std allowlist, our own codecs

## Context and Problem Statement

`import Lean` links large parts of the Lean compiler, and `Lean.Data.Json` needs it. Embedded and mobile targets need a small binary, and the Lean runtime can link GMP, which is LGPL.

## Considered Options

* Runtime imports only `Init` and an allowlist of `Std` modules; compile-time code (`AgentLean.Meta`) may import `Lean` but is never linked
* Use `Lean.Data.Json` and the full library
* Ban `Std` entirely

## Decision Outcome

Chosen option: "Init plus a Std allowlist", with four rules: (1) two tiers, `AgentLean` runtime and `AgentLean.Meta` compile-time, with CI failing on any forbidden runtime import; (2) our own minimal JSON and SSE codecs in pure Lean, with round-trip and failure theorems; (3) a CI size budget for a stripped static reference agent, its number set by the feasibility spike; (4) an audit of GMP linkage, building with Lean's own bignum implementation for mobile if the release links GMP.

### Consequences

* Good, because the binary stays small and the codecs become part of the proof story.
* Bad, because we write and maintain codecs and some utilities the full library already has.

## More Information

Capability `openspec:portable-build`. Constraint: LGPL obligations of GMP (`tg.md/constraints.md`).
