## Purpose

The host ABI is how applications in C, Swift, Kotlin and Lean run agents. It keeps the host in control of threads, networking and secrets, and keeps every binding thin.

## ADDED Requirements

### Requirement: Pull-based driving
The host SHALL drive an agent by feeding events and pulling pending effects, and the library SHALL never call into host code or start threads.

#### Scenario: Host loop round trip
- **WHEN** the host feeds a user message and pulls effects until none remain
- **THEN** it receives a model-request effect and no host function was called by the library

### Requirement: Handle thread confinement
An agent handle SHALL be safe to use from any one thread at a time, and distinct handles SHALL be fully independent.

#### Scenario: Two agents on two threads
- **WHEN** two agents are driven concurrently, each from its own thread
- **THEN** each produces the same trace it produces when run alone

### Requirement: JSON payloads
Events, effects, configuration and snapshots SHALL cross the ABI as JSON bytes, and an invalid payload SHALL return an error code without changing the agent's state.

#### Scenario: Invalid event rejected
- **WHEN** the host feeds bytes that are not a valid event
- **THEN** the call returns an invalid-event error and the agent's next snapshot equals the one before the call

### Requirement: Credentials by reference
Model-request effects SHALL name the credential to use by reference, and no credential value SHALL ever appear in an effect, the trace or a snapshot.

#### Scenario: Effect carries reference, not key
- **WHEN** the core emits a model request for a provider configured with credential `openai`
- **THEN** the effect contains the reference `openai` and contains no API key

### Requirement: Lean driver
Lean programs SHALL be able to run an agent end to end on Linux and macOS, including HTTP and TLS to a model endpoint, without writing C.

#### Scenario: Driver runs agent against endpoint
- **WHEN** a Lean program runs an agent through the driver against an OpenAI-compatible endpoint
- **THEN** the run completes and the trace is identical to one produced through the C ABI with the same responses

### Requirement: Native bindings
Swift and Kotlin bindings SHALL wrap the ABI through each platform's native FFI and SHALL behave identically to the C ABI.

#### Scenario: Golden trace through bindings
- **WHEN** the golden traces are replayed through the Swift binding and the Kotlin binding
- **THEN** both produce the same effects as the C ABI, byte for byte
