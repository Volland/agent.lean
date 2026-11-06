/* The reference agent used for the binary size budget: one turn with a tool call and an answer. */
#include "agent.h"
#include <stdio.h>
#include <string.h>

static void feed(agent_t *a, const char *ev) { agent_feed(a, (const uint8_t *)ev, strlen(ev)); }

int main(void) {
  const char *cfg = "{\"agent\":\"assistant\",\"model\":\"m\",\"endpoint\":\"http://localhost:8080/v1/chat/completions\"}";
  agent_t *a = agent_new((const uint8_t *)cfg, strlen(cfg), NULL);
  if (!a) return 1;
  feed(a, "{\"type\":\"user\",\"text\":\"add 2 and 3\"}");
  agent_buf_t e;
  while (agent_next_effect(a, &e)) agent_buf_free(e);
  feed(a, "{\"type\":\"llm_response\",\"id\":\"r1\",\"body\":\"{\\\"choices\\\":[{\\\"message\\\":{\\\"content\\\":null,\\\"tool_calls\\\":[{\\\"id\\\":\\\"c\\\",\\\"type\\\":\\\"function\\\",\\\"function\\\":{\\\"name\\\":\\\"add\\\",\\\"arguments\\\":\\\"{\\\\\\\"a\\\\\\\":2,\\\\\\\"b\\\\\\\":3}\\\"}}]}}]}\"}");
  while (agent_next_effect(a, &e)) agent_buf_free(e);
  feed(a, "{\"type\":\"llm_response\",\"id\":\"r2\",\"body\":\"{\\\"choices\\\":[{\\\"message\\\":{\\\"content\\\":\\\"5\\\"}}]}\"}");
  int ok = 0;
  while (agent_next_effect(a, &e)) { ok |= strstr((char *)e.data, "\"answer\":\"5\"") != NULL; agent_buf_free(e); }
  agent_free(a);
  printf(ok ? "ref_agent: ok\n" : "ref_agent: FAILED\n");
  return ok ? 0 : 1;
}
