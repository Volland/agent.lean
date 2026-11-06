## Purpose

The agent core decides what an agent does next. It is a pure, deterministic state machine that turns events (user input, model output, tool results) into effects for the host to perform.

## ADDED Requirements

### Requirement: Pure step function
The core SHALL expose its behaviour only as a deterministic transition from a state and an event to a new state and an ordered list of effects, and SHALL perform no IO of its own.

#### Scenario: Same inputs give same outputs
- **WHEN** the same state and the same event are given to the core twice
- **THEN** both calls return an identical new state and an identical list of effects

#### Scenario: No IO from the core
- **WHEN** the core processes any event
- **THEN** every network request, tool execution, clock read and storage write appears as an effect for the host, not as an action of the core

### Requirement: ReAct loop
The core SHALL alternate model requests and tool calls until the model gives a final answer, a budget is exhausted, or the host cancels the run.

#### Scenario: Final answer ends the run
- **WHEN** the model responds with a final answer and no tool calls
- **THEN** the core emits a completion effect carrying the answer and accepts no further model or tool events for that run

#### Scenario: Tool result triggers next model request
- **WHEN** the result of the last outstanding tool call arrives
- **THEN** the core emits a model request whose context includes that result

#### Scenario: Cancellation ends the run
- **WHEN** the host sends a cancel event while effects are outstanding
- **THEN** the core emits a cancelled completion and ignores later results for that run

### Requirement: Run budgets
The core SHALL enforce configured limits on steps, tool calls and tokens, and SHALL NOT emit an effect that would exceed any of them.

#### Scenario: Tool-call budget exhausted
- **WHEN** the model requests a tool call after the tool-call budget is spent
- **THEN** the core emits no tool effect and ends the run with a budget-exhausted completion

#### Scenario: Every run terminates
- **WHEN** a run is driven by any sequence of well-formed events
- **THEN** it reaches a completion within the configured step budget

### Requirement: Parallel tool calls
The core SHALL emit one effect per tool call when a model response contains several, and SHALL accept their results in any order, matched by call id.

#### Scenario: Results arrive out of order
- **WHEN** a response requests tools A and B and the result of B arrives before the result of A
- **THEN** the core records both results against the right calls and issues the next model request only after both arrived

### Requirement: UI events
The core SHALL emit display-only events for streaming text and for tool start and end, and its state transitions SHALL NOT depend on the host handling them.

#### Scenario: Token deltas while streaming
- **WHEN** a streamed model response delivers text in chunks
- **THEN** the core emits one text-delta UI event per decoded chunk

### Requirement: Agent as tool
An agent SHALL be usable as a tool of another agent, and the child run's budgets SHALL never exceed the parent's remaining budgets.

#### Scenario: Child cannot exceed parent budget
- **WHEN** a parent with 3 tool calls remaining invokes a child agent configured for 10
- **THEN** the child runs with at most 3 tool calls and its usage is charged to the parent

### Requirement: Context window policy
The core SHALL build each model request within the model's context limit according to a conservative token estimate, SHALL always keep pinned content (system prompt, tool schemas, last user turn), and SHALL elide the oldest tool results first.

#### Scenario: Oldest tool result elided
- **WHEN** the history would exceed the context limit
- **THEN** the oldest tool result is replaced by an elision marker before any turn is dropped

#### Scenario: Pinned content never dropped
- **WHEN** a request is built under any history length
- **THEN** it contains the system prompt, the tool schemas and the last user turn
