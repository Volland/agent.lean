# trace-replay Specification

## Purpose
The trace is the append-only record of every event a run received. It is the source of truth for persistence, resume after a crash, deterministic replay and audit.

## Requirements

### Requirement: Append-only trace
The core SHALL record every event it accepts, in the order it accepted them, and SHALL never rewrite a recorded entry.

#### Scenario: Parallel results recorded in arrival order
- **WHEN** results for parallel calls A and B arrive in the order B, A
- **THEN** the trace records B before A

### Requirement: Deterministic replay
Replaying a trace from the initial state SHALL reproduce the same states and the same effects as the original run.

#### Scenario: Replay reproduces effects
- **WHEN** a recorded trace is replayed into a fresh agent with the same configuration
- **THEN** the effects emitted equal the effects of the original run, in the same order

### Requirement: Snapshot and resume
The core SHALL serialize its state as a snapshot and SHALL resume from a snapshot plus the events after it with the same result as replaying the full trace.

#### Scenario: Resume from snapshot equals full replay
- **WHEN** an agent resumes from a snapshot taken at event N and is fed events N+1 onward
- **THEN** its state equals the state reached by replaying events 1 onward from the start

### Requirement: Versioned format
Traces and snapshots SHALL carry a format version, and the core SHALL refuse a version it does not support with an explicit error.

#### Scenario: Unknown version rejected
- **WHEN** the core is given a snapshot with an unsupported format version
- **THEN** it returns an unsupported-version error and creates no agent

### Requirement: Sensitive trace marking
The core SHALL report whether a trace contains output of tools declared sensitive, so the host can encrypt it at rest.

#### Scenario: Sensitive flag raised
- **WHEN** a tool declared sensitive returns a result
- **THEN** the trace is reported as containing sensitive data from then on

### Requirement: Audit export
The core SHALL export a trace for audit in which payloads of sensitive tools are replaced by cryptographic hashes and every other entry is unchanged.

#### Scenario: Sensitive result hashed in export
- **WHEN** a trace containing a sensitive tool result is exported for audit
- **THEN** the export contains the hash of that result instead of its content
