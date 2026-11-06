# agent_llama: local inference as a byte transport

`agent_llama` runs a GGUF model in-process with [llama.cpp](https://github.com/ggml-org/llama.cpp)
and answers the agent core's `llm_request` effects exactly as an HTTP endpoint would: an
OpenAI-compatible Chat Completions request body in, an OpenAI-compatible response body out
([ADR 0004](../../docs/adr/0004-local-inference-transport-adapter.md)). The core never learns whether
a response came from a remote API or from the phone it runs on.

## Fetch and build

```sh
scripts/fetch_llama.sh   # llama.cpp b12169 -> build/llama/llama.cpp (shallow)
                         # Qwen2.5-0.5B-Instruct Q4_K_M (~470 MiB) -> build/llama/models/
                         # static llama, ggml (Metal on macOS, CPU elsewhere), llama-common -> build/llama/build
scripts/test_llama.sh    # builds agent_llama + tests, runs the transport-neutrality and constrained-decoding checks
```

Both scripts need CMake 3.20+, a C++17 compiler, git and curl. Everything they write stays under
`build/llama/` (gitignored). To use the adapter in another CMake project, add `c/llama` with
`add_subdirectory` (set `LLAMA_CPP_DIR` to a llama.cpp checkout) and link `agent_llama`.

## API

```c
#include "agent_llama.h"

agent_llama_t *agent_llama_open(const char *gguf_path, int n_ctx, agent_buf_t *err);
agent_buf_t    agent_llama_complete(agent_llama_t *, const uint8_t *request_body, size_t len, int *status);
void           agent_llama_close(agent_llama_t *);
```

A host loop serves `llm_request` effects with it instead of an HTTP client:

```c
agent_buf_t eff;
while (agent_next_effect(agent, &eff)) {
  /* eff: {"type":"llm_request","id":"r1","url":...,"body":"<Chat Completions request JSON>",...} */
  int status;
  agent_buf_t resp = agent_llama_complete(llm, body, body_len, &status);
  /* feed {"type":"llm_response","id":"r1","status":<status>,"body":"<resp as a JSON string>"} */
  agent_buf_free(resp);
  agent_buf_free(eff);
}
```

`url`, `credential`, `auth` and `headers` of the effect are ignored: there is nothing to connect to.

What a request goes through, the way `llama-server` handles `/v1/chat/completions`, using llama.cpp's
own `common` chat machinery (`common/chat.h`, `common_chat_session`):

- **Prompt**: the model's Jinja chat template renders `messages` and `tools`.
- **Constrained tool calls**: the tools' JSON schemas are compiled into a GBNF grammar. With
  `tool_choice` `auto` the grammar is lazy: free text is unconstrained, and from the tool-call trigger
  on (for Qwen, `<tool_call>`) every token must keep the output inside the grammar -- a declared tool
  name and arguments matching that tool's schema (required keys, types, integer bounds,
  `additionalProperties:false`). With `tool_choice` `required` a tool call is mandatory.
- **Parsing**: the output is parsed back into `content` and `tool_calls` (`arguments` as a JSON string).
- **Determinism**: greedy sampling (top-k 1), the KV cache cleared per request, tool call ids
  `call_<request#>_<i>` and response ids `chatcmpl-local-<request#>` from a per-handle counter, no
  timestamps. The same requests on a fresh handle give the same bytes.

Honoured request keys: `messages`, `tools`, `tool_choice` (string form), `parallel_tool_calls`,
`max_tokens` / `max_completion_tokens`, `stop`, `model` (echoed). `"stream": true` is refused with
status 400. Errors come back as `{"error":{"message":...,"type":...}}` with status 400 or 500, which
the core treats like any HTTP error. A handle is used by one thread at a time; the returned buffer is
malloc'd and freed with `agent_buf_free`.

## Tests

- `llama_run --model M --golden OUT [PROMPT]` drives the example `assistant` through the C ABI with
  every `llm_request` served locally (the pure tool `add` runs inside the core; host and io tools get
  fixed stub results) and writes the run in the golden-trace format (`C` config, `E` event, `X` effect
  lines, as `driver_demo --golden` does).
- `scripts/test_llama.sh` runs it twice and requires identical files, then replays the file with
  `llama_conformance` (`c/tests/conformance.c`): the same response bytes fed as ordinary events -- as an
  HTTP host would -- must give identical effects (`openspec:llm-codecs` "Transport neutrality").
- `llama_constrained --model M` sends eight varied tool prompts (as the assistant's real request
  bodies, with `tool_choice` `auto` and `required`) and checks every returned tool call against its
  tool's schema (`openspec:llm-codecs` "Local constrained decoding").

## Other on-device engines (MLX, Core ML, MediaPipe)

The contract is one function: request body bytes in, response body bytes out. A mobile host that
runs a model with MLX (Swift), Core ML or MediaPipe LLM Inference implements the same function in its
own language and serves `llm_request` effects with it; nothing in the core changes.

```swift
// Swift host, MLX or Core ML behind it
func complete(_ requestBody: Data) -> (status: Int, body: Data) {
  let req = try JSONDecoder().decode(ChatRequest.self, from: requestBody)  // messages, tools
  let prompt = chatTemplate.render(req.messages, tools: req.tools)        // the model's own template
  let out = model.generate(prompt, grammar: grammar(for: req.tools), temperature: 0)
  return (200, encodeChatCompletion(parseToolCalls(out)))                 // OpenAI response shape
}
// host loop: on {"type":"llm_request",...} feed {"type":"llm_response","id":..,"status":..,"body":..}
```

What such an adapter must keep to be a drop-in transport:

1. Accept the OpenAI Chat Completions request the core emits and return the OpenAI response shape
   (`choices[0].message.content` and/or `tool_calls[{id,type:"function",function:{name,arguments}}]`,
   `finish_reason`, `usage`), or an error body with a non-200 status.
2. Constrain tool-call arguments to each tool's schema where the engine allows it (MLX and
   llama.cpp take grammars or JSON schemas; where an engine cannot, validate against the schema and
   retry before answering).
3. Be deterministic when replayability matters (greedy decoding, ids from a counter), so a recorded
   run reproduces.
