/* agent_llama: in-process local inference as a byte transport (ADR 0004).
 *
 * The adapter has the same contract as the HTTP transport: the host takes the "body" of an
 * llm_request effect (an OpenAI-compatible Chat Completions request), passes it to
 * agent_llama_complete instead of POSTing it, and feeds the returned bytes back as
 *
 *   {"type":"llm_response","id":<effect id>,"status":<status>,"body":<returned bytes as a JSON string>}
 *
 * The core cannot tell a local model from a remote endpoint. Generation is greedy (deterministic),
 * tool-call arguments are grammar-constrained to each tool's JSON schema, and tool call ids are
 * derived from a per-handle request counter, so the same requests give the same bytes.
 *
 * A handle may be used from any thread, but by one thread at a time.
 */
#ifndef AGENT_LLAMA_H
#define AGENT_LLAMA_H

#include "agent.h" /* agent_buf_t, agent_buf_free */

#ifdef __cplusplus
extern "C" {
#endif

typedef struct agent_llama agent_llama_t;

/* Load a GGUF model with a context of n_ctx tokens (<= 0: 4096). Returns NULL on error; if `err` is
 * not NULL it receives the message (release it with agent_buf_free). */
agent_llama_t *agent_llama_open(const char *gguf_path, int n_ctx, agent_buf_t *err);

/* request_body: OpenAI-compatible Chat Completions request JSON (the llm_request effect's "body";
 * honoured keys: messages, tools, tool_choice, parallel_tool_calls, max_tokens /
 * max_completion_tokens, stop, model). Returns an OpenAI-compatible Chat Completions response JSON
 * (choices[0].message with content and/or tool_calls, finish_reason, usage) and sets *status to 200;
 * on error returns {"error":{"message":...,"type":...}} with status 400 (bad request) or 500.
 * "stream":true is refused with status 400 (the adapter answers whole responses only).
 * The buffer is malloc'd: free it with agent_buf_free. */
agent_buf_t agent_llama_complete(agent_llama_t *l, const uint8_t *request_body, size_t len, int *status);

void agent_llama_close(agent_llama_t *l);

#ifdef __cplusplus
}
#endif
#endif
