---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# The Lean driver loads libcurl at run time

## Context and Problem Statement

Lean has no HTTP or TLS client, so `AgentLean.Driver` uses libcurl. Linking it failed on macOS: the linker bundled with the Lean toolchain cannot read the current SDK's library stubs.

## Considered Options

* `dlopen` libcurl at first use and resolve the nine functions the driver needs
* Link `-lcurl` with per-platform linker flags
* Write an HTTP client in Lean over sockets (no TLS)

## Decision Outcome

Chosen option: "dlopen at run time", because building and linking then need no curl headers or flags on any platform, and a missing libcurl becomes an `llm_error` event instead of a build failure.

### Consequences

* Good, because `lake build` works on stock macOS and Linux.
* Bad, because a wrong libcurl ABI would only show at run time; the nine functions used have been stable for over a decade.

## More Information

Capability `openspec:host-abi` (requirement "Lean driver"). Implemented in `c/agent_curl.c`.
