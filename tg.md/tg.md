# Project

This directory defines the high-level concepts, business logic and architecture of the project in markdown, managed with the `tg` CLI (compatible with lat.md). Run `tg check` to validate it.

- [[code-ontology]] — shared vocabulary of intent types and typed edges between intent and code
- [[architecture]] — concepts of agent.lean: step machine, events, effects, trace, transport, tools, policies, host, bundle
- [[decisions]] — design decisions mirroring ADRs 0002–0012, with what motivates each
- [[constraints]] — external rules from the Lean toolchain, platforms, licences and LLMs that bind the decisions
