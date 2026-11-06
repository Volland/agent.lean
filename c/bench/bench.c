/* agent.lean benchmarks: cold start, step overhead, codec throughput, memory per agent.
 * Prints one JSON object; scripts/check_budgets.py compares it with bench/budgets.json.
 * @tg: verifies:: [[openspec:portable-build#Performance budgets#Step overhead regression fails CI]] {level: e2e} */
#include "agent.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/resource.h>

static double now_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return (double)t.tv_sec * 1e6 + (double)t.tv_nsec / 1e3;
}

#ifdef __APPLE__
#include <mach/mach.h>
#else
#include <unistd.h>
#endif

/* Current resident set size in KiB. */
static long rss_kb(void) {
#ifdef __APPLE__
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
  return (long)(info.resident_size / 1024);
#else
  long pages = 0, resident = 0;
  FILE *f = fopen("/proc/self/statm", "r");
  if (!f) return 0;
  if (fscanf(f, "%ld %ld", &pages, &resident) != 2) resident = 0;
  fclose(f);
  return resident * (sysconf(_SC_PAGESIZE) / 1024);
#endif
}

static const char *CFG = "{\"agent\":\"assistant\",\"model\":\"m\",\"endpoint\":\"http://localhost/v1/chat/completions\"}";
static const char *USER = "{\"type\":\"user\",\"text\":\"hello\"}";
static const char *REPLY = "{\"type\":\"llm_response\",\"id\":\"r1\",\"body\":\"{\\\"choices\\\":[{\\\"message\\\":{\\\"content\\\":\\\"hi\\\"}}]}\"}";

static void drain(agent_t *a) { agent_buf_t e; while (agent_next_effect(a, &e)) agent_buf_free(e); }
static int feed(agent_t *a, const char *s) { return agent_feed(a, (const uint8_t *)s, strlen(s)); }

int main(int argc, char **argv) {
  int iters = argc > 1 ? atoi(argv[1]) : 2000;
  double t0 = now_us();
  agent_t *a = agent_new((const uint8_t *)CFG, strlen(CFG), NULL);
  double cold = now_us() - t0;
  if (!a) { fprintf(stderr, "agent_new failed\n"); return 1; }
  agent_free(a);

  /* step overhead: one user event and one small model reply per agent, effects drained */
  double t1 = now_us();
  for (int i = 0; i < iters; i++) {
    agent_t *x = agent_new((const uint8_t *)CFG, strlen(CFG), NULL);
    feed(x, USER); drain(x);
    feed(x, REPLY); drain(x);
    agent_free(x);
  }
  double step = (now_us() - t1) / (2.0 * iters);

  /* codec throughput: one large non-streamed reply */
  size_t n = 1 << 20;
  char *big = (char *)malloc(n + 512);
  int k = sprintf(big, "{\"type\":\"llm_response\",\"id\":\"r1\",\"body\":\"{\\\"choices\\\":[{\\\"message\\\":{\\\"content\\\":\\\"");
  memset(big + k, 'a', n); k += (int)n;
  k += sprintf(big + k, "\\\"}}]}\"}");
  agent_t *y = agent_new((const uint8_t *)CFG, strlen(CFG), NULL);
  feed(y, USER); drain(y);
  double t2 = now_us();
  int code = feed(y, big);
  drain(y);
  double codec = (double)n / (now_us() - t2); /* bytes per microsecond == MB/s */
  agent_free(y);
  free(big);
  if (code != 0) { fprintf(stderr, "big reply rejected\n"); return 1; }

  /* memory: RSS growth per idle agent after one user turn */
  enum { M = 200 };
  agent_t *many[M];
  long r0 = rss_kb();
  for (int i = 0; i < M; i++) { many[i] = agent_new((const uint8_t *)CFG, strlen(CFG), NULL); feed(many[i], USER); drain(many[i]); }
  long r1 = rss_kb();
  for (int i = 0; i < M; i++) agent_free(many[i]);

  printf("{\"cold_start_us\":%.1f,\"step_overhead_us\":%.2f,\"codec_mb_s\":%.1f,\"memory_kb_per_agent\":%.1f,\"rss_kb\":%ld}\n",
         cold, step, codec, (double)(r1 - r0) / M, r1);
  return 0;
}
