# llm-codecs Specification

## Purpose
LLM codecs turn the core's model requests into provider wire bytes and provider responses back into typed events, identically on every platform, so hosts only move bytes.

## Requirements

### Requirement: OpenAI-compatible codec
The core SHALL encode model requests and decode responses in the OpenAI-compatible Chat Completions format, including tool definitions and tool calls.

#### Scenario: Tool call parsed from response
- **WHEN** a Chat Completions response contains a `tool_calls` entry
- **THEN** the core produces a tool-call event with the same call id, tool name and arguments

#### Scenario: Request carries tool schemas
- **WHEN** the core encodes a model request for an agent with declared tools
- **THEN** the request body lists every declared tool with its derived schema

### Requirement: Anthropic Messages codec
The core SHALL encode model requests and decode responses in the Anthropic Messages format, including `tool_use` and `tool_result` blocks.

#### Scenario: tool_use block parsed
- **WHEN** a Messages response contains a `tool_use` block
- **THEN** the core produces a tool-call event with the block's id, name and input

### Requirement: Streaming decoding
The core SHALL decode server-sent-event streams incrementally, giving the same result regardless of how the byte stream is split into chunks.

#### Scenario: Chunk split mid-event
- **WHEN** a stream is delivered with chunk boundaries inside an event and inside a UTF-8 character
- **THEN** the decoded events equal those decoded from the same stream delivered in one chunk

### Requirement: Malformed model output
The core SHALL treat any response bytes it cannot decode as an error event for the run, and SHALL never crash or emit a tool effect from undecodable output.

#### Scenario: Truncated JSON
- **WHEN** a response body ends in the middle of a JSON object
- **THEN** the core produces a decode-error event and emits no tool effect

### Requirement: Transport neutrality
The core's behaviour SHALL depend only on the bytes it receives, not on whether they came from a remote endpoint or an in-process local model.

#### Scenario: Same trace via local adapter
- **WHEN** a recorded run's model responses are served once through the HTTP transport and once through the local adapter
- **THEN** both runs produce identical traces

### Requirement: Local constrained decoding
The local inference adapter SHALL constrain generation of tool arguments to the tool's derived schema.

#### Scenario: Small model cannot emit malformed arguments
- **WHEN** a local model generates a tool call through the adapter
- **THEN** the arguments always decode into the tool's input type
