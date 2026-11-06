## Purpose

Policies state which tool calls an agent may make, with which arguments and in which order. They are enforced by the core on every step, so a rule holds by construction rather than by prompt.

## ADDED Requirements

### Requirement: Per-call guards
The core SHALL evaluate each tool call's guard on its decoded arguments before emitting the call.

#### Scenario: Guard blocks out-of-range argument
- **WHEN** a policy limits `transfer.amount` to 100 and the model calls `transfer` with amount 250
- **THEN** no tool effect is emitted and the call is treated as a policy violation

### Requirement: Temporal trace policies
The core SHALL enforce policies stated over the history of the run (what happened before, since, and how often), and SHALL evaluate them before emitting each tool call.

#### Scenario: Confirmation required before payment
- **WHEN** a policy requires `confirm_user` since the last user turn before `send_payment` and the model calls `send_payment` without it
- **THEN** the call is treated as a policy violation

#### Scenario: Call count limit per turn
- **WHEN** a policy allows at most 3 `web_fetch` calls per user turn and the model requests a fourth
- **THEN** the fourth call is treated as a policy violation

### Requirement: Monitor soundness
The verdict the core reaches for a policy on each step SHALL equal the verdict of evaluating that policy over the whole trace so far, at a per-step cost independent of the trace length.

#### Scenario: Verdict matches full-trace evaluation
- **WHEN** any trace is fed event by event to the core
- **THEN** each step's policy verdict equals the policy evaluated over the trace up to that step

### Requirement: Recoverable violations
By default a policy violation SHALL be returned to the model as a refusal naming the policy, recorded in the trace, and the run SHALL continue.

#### Scenario: Blocked call becomes refusal
- **WHEN** a call violates a recoverable policy
- **THEN** the model receives a refusal that names the policy and the run continues with the next model request

### Requirement: Halting violations
A policy marked as halting SHALL end the run on violation with a completion that names the policy.

#### Scenario: Halt policy stops agent
- **WHEN** a call violates a policy marked halting
- **THEN** no further effects are emitted except a policy-halt completion naming the policy

### Requirement: Taint-based information flow
Policies SHALL be able to refer to whether untrusted data has entered the run's context, so that sensitive actions can be blocked after untrusted input unless confirmed.

#### Scenario: Untrusted content blocks send without confirmation
- **WHEN** a `web_fetch` result labelled untrusted is in context and a policy forbids `send_email` after untrusted data unless `confirm_user` follows it
- **THEN** a `send_email` call without a later `confirm_user` is a policy violation
