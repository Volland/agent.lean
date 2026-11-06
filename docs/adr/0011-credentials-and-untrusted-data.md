---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Credentials never enter the core; sensitive data is kept for replay and encrypted by the host

## Context and Problem Statement

The core builds request bytes and records everything in the trace, which is persisted, exported and replayed. API keys and sensitive tool output could leak through it.

## Considered Options

* Credentials by reference, sensitive payloads kept in the trace, encrypted at rest by the host, hashed on audit export
* Credentials by reference, sensitive payloads stored as hashes only (privacy-first, no replay)

## Decision Outcome

Chosen option: "keep payloads, encrypt at rest, hash on export", because deterministic replay is a core guarantee and hash-only storage breaks it for sensitive tools. Requests carry a `credential_ref`; the host transport injects the real header from the Keychain, the Android Keystore or a file. A `Secret` type has no serialization instance, so leaking a secret into a trace is a type error. Tool output and model output are untrusted, and taint labels feed information-flow policies (ADR 0009).

### Consequences

* Good, because secrets cannot reach traces or snapshots by construction.
* Bad, because hosts must encrypt traces flagged as sensitive.

## More Information

Capabilities `openspec:host-abi`, `openspec:trace-replay` and `openspec:policies`.
