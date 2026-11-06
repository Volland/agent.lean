/* agent.lean C ABI.
 *
 * The host drives an agent by feeding events and pulling effects; the library never calls into
 * the host and never starts threads (ADR 0007). Events, effects, configuration and snapshots are
 * UTF-8 JSON. A handle may be used from any thread, but by one thread at a time; distinct handles
 * are independent.
 *
 *   agent_t *a = agent_new(cfg, cfg_len, NULL);
 *   agent_feed(a, user_event, len);
 *   agent_buf_t e;
 *   while (agent_next_effect(a, &e)) { ... perform it, feed the result ...; agent_buf_free(e); }
 *   agent_free(a);
 */
#ifndef AGENT_LEAN_H
#define AGENT_LEAN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define AGENT_LEAN_ABI_VERSION 1

typedef struct agent agent_t;

/* A byte buffer owned by the caller; release it with agent_buf_free. */
typedef struct {
  uint8_t *data; /* NUL-terminated for convenience; `len` excludes the NUL */
  size_t len;
} agent_buf_t;

enum {
  AGENT_OK = 0,
  AGENT_INVALID = 1,  /* the event is not valid JSON or not a known event */
  AGENT_REJECTED = 2, /* the event is not expected in the current state; nothing changed */
  AGENT_FAILED = -1   /* the call failed (out of memory, bad handle) */
};

/* Create an agent from a run configuration, e.g.
 * {"agent":"pay","model":"gpt-4.1-mini","endpoint":"https://api.openai.com/v1/chat/completions"}.
 * Returns NULL on error; if `err` is not NULL it receives the message. */
agent_t *agent_new(const uint8_t *config, size_t len, agent_buf_t *err);

/* Recreate an agent from agent_snapshot output. Feed {"type":"resume"} next to re-issue what was
 * in flight. Returns NULL on error. */
agent_t *agent_restore(const uint8_t *snapshot, size_t len, agent_buf_t *err);

/* Feed one event. Returns AGENT_OK, AGENT_INVALID or AGENT_REJECTED (state unchanged). */
int agent_feed(agent_t *a, const uint8_t *event, size_t len);

/* Pull the next effect. Returns 1 and fills `out` if there is one, 0 if none. */
int agent_next_effect(agent_t *a, agent_buf_t *out);

/* The state as a versioned snapshot. */
agent_buf_t agent_snapshot(agent_t *a);

/* The append-only trace of accepted events, and its audit form (sensitive payloads hashed). */
agent_buf_t agent_trace(agent_t *a);
agent_buf_t agent_audit(agent_t *a);
uint64_t agent_trace_len(agent_t *a);

/* Message of the last AGENT_INVALID / AGENT_REJECTED. */
agent_buf_t agent_last_error(agent_t *a);

int agent_is_done(agent_t *a);
/* 1 once output of a tool declared sensitive entered the run: encrypt the trace at rest. */
int agent_is_sensitive(agent_t *a);

void agent_buf_free(agent_buf_t b);
void agent_free(agent_t *a);

#ifdef __cplusplus
}
#endif
#endif
