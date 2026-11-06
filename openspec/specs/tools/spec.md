# tools Specification

## Purpose
Tools are the only way an agent acts on the world. This capability fixes how tools are declared, typed, executed and checked, so a tool never sees input it was not designed for.

## Requirements

### Requirement: Typed tool arguments
The core SHALL decode the model's arguments for a tool into that tool's declared input type before execution, and SHALL return a structured error to the model instead of executing when decoding fails.

#### Scenario: Malformed arguments rejected
- **WHEN** the model calls a tool with arguments that do not match its input type
- **THEN** the tool is not executed and the model receives an error naming the field that failed

#### Scenario: Unknown tool name rejected
- **WHEN** the model calls a tool name that the agent does not declare
- **THEN** no effect is emitted for it and the model receives an unknown-tool error listing the declared names

### Requirement: Schema derived from tool type
Each tool's JSON Schema SHALL be derived from its declared input type, and a value SHALL satisfy the schema exactly when it decodes into the type.

#### Scenario: Schema matches type
- **WHEN** a tool's input type has a required string field and an optional integer field
- **THEN** its schema marks the string as required and the integer as optional with integer type

### Requirement: Tool executors
A tool SHALL run in exactly one of three ways: inside the core (pure), in the Lean driver (io), or in the host application (host), and the model-facing behaviour SHALL be the same for all three.

#### Scenario: Pure tool runs without host round trip
- **WHEN** the model calls a pure tool
- **THEN** its result is computed inside the core and no tool effect is emitted to the host

#### Scenario: Host tool result decoded and checked
- **WHEN** the host returns a result for a host tool
- **THEN** the core decodes it into the tool's output type and rejects it with an error if decoding fails

### Requirement: Static tool registry
The set of tools an agent may call SHALL be fixed when the agent is built, and the host SHALL NOT be able to add tools at runtime.

#### Scenario: Host offers undeclared tool
- **WHEN** the host supplies an implementation for a tool name the agent does not declare
- **THEN** creating the agent fails with an undeclared-tool error

### Requirement: Tool contracts
A tool MAY declare a precondition on its input and a postcondition on its input and output; the core SHALL check both and SHALL report a violation to the model instead of passing on the result.

#### Scenario: Precondition blocks execution
- **WHEN** decoded arguments violate the tool's precondition
- **THEN** the tool is not executed and the model receives a precondition error

#### Scenario: Postcondition failure
- **WHEN** a tool's result violates its postcondition
- **THEN** the result is discarded and the model receives a postcondition error

### Requirement: Idempotency declaration
Every tool SHALL declare whether it is idempotent, with no default, and on resume after a crash the core SHALL re-issue an in-flight call only if its tool is idempotent.

#### Scenario: Non-idempotent in-flight call after crash
- **WHEN** a run resumes with a call to a non-idempotent tool that has no recorded result
- **THEN** the call is marked failed with an interrupted error and is not re-issued

#### Scenario: Idempotent in-flight call after crash
- **WHEN** a run resumes with a call to an idempotent tool that has no recorded result
- **THEN** the core emits the same tool effect again

### Requirement: Data labels
Every tool SHALL declare whether its output is trusted or untrusted and whether it is sensitive, and the core SHALL carry these labels into the trace.

#### Scenario: Untrusted label recorded
- **WHEN** a tool declared untrusted returns a result
- **THEN** the trace entry for that result carries the untrusted label
