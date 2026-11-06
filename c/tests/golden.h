/* Replay a golden trace (traces/NAME.golden) through the C ABI and compare effects byte for byte. */
#ifndef AGENT_GOLDEN_H
#define AGENT_GOLDEN_H
#include "agent.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char **lines; size_t n; } golden_t;

static int golden_load(const char *path, golden_t *g) {
  FILE *f = fopen(path, "rb");
  if (!f) return -1;
  g->lines = NULL; g->n = 0;
  char *line = NULL; size_t cap = 0; ssize_t len;
  while ((len = getline(&line, &cap, f)) > 0) {
    if (line[len - 1] == '\n') line[--len] = 0;
    if (len == 0) continue;
    g->lines = (char **)realloc(g->lines, (g->n + 1) * sizeof(char *));
    g->lines[g->n++] = strdup(line);
  }
  free(line);
  fclose(f);
  return 0;
}

static void golden_free(golden_t *g) {
  for (size_t i = 0; i < g->n; i++) free(g->lines[i]);
  free(g->lines);
}

/* Returns 0 if the run reproduces every expected effect exactly; prints the first difference. */
static int golden_run(const golden_t *g, const char *name, int verbose) {
  if (g->n == 0 || strncmp(g->lines[0], "C ", 2) != 0) { fprintf(stderr, "%s: no config line\n", name); return 1; }
  agent_buf_t err;
  const char *cfg = g->lines[0] + 2;
  agent_t *a = agent_new((const uint8_t *)cfg, strlen(cfg), &err);
  if (!a) { fprintf(stderr, "%s: agent_new failed: %s\n", name, err.data ? (char *)err.data : "?"); agent_buf_free(err); return 1; }
  int rc = 0;
  size_t i = 1;
  while (i < g->n && rc == 0) {
    const char *l = g->lines[i];
    if (strncmp(l, "E ", 2) != 0) { fprintf(stderr, "%s:%zu: expected an event line\n", name, i + 1); rc = 1; break; }
    int code = agent_feed(a, (const uint8_t *)l + 2, strlen(l + 2));
    if (code != AGENT_OK) {
      agent_buf_t e = agent_last_error(a);
      fprintf(stderr, "%s:%zu: event rejected (%d): %s\n", name, i + 1, code, (char *)e.data);
      agent_buf_free(e); rc = 1; break;
    }
    i++;
    agent_buf_t eff;
    while (agent_next_effect(a, &eff)) {
      if (i >= g->n || strncmp(g->lines[i], "X ", 2) != 0) {
        fprintf(stderr, "%s:%zu: unexpected extra effect %s\n", name, i + 1, (char *)eff.data); rc = 1;
      } else if (strcmp(g->lines[i] + 2, (char *)eff.data) != 0) {
        fprintf(stderr, "%s:%zu: effect differs\n  want %s\n  got  %s\n", name, i + 1, g->lines[i] + 2, (char *)eff.data);
        rc = 1;
      }
      agent_buf_free(eff);
      i++;
      if (rc) break;
    }
    if (rc == 0 && i < g->n && strncmp(g->lines[i], "X ", 2) == 0) {
      fprintf(stderr, "%s:%zu: missing effect %s\n", name, i + 1, g->lines[i] + 2); rc = 1;
    }
  }
  if (verbose && rc == 0) printf("  ok    %s\n", name);
  agent_free(a);
  return rc;
}
#endif
