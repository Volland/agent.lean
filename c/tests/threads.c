/* Two agents on two threads, each must produce exactly the trace it produces alone.
 * @tg: verifies:: [[openspec:host-abi#Handle thread confinement#Two agents on two threads]] {level: integration} */
#include "golden.h"
#include <pthread.h>

typedef struct { golden_t *g; const char *name; int rounds; int failures; } job_t;

static void *worker(void *p) {
  job_t *j = (job_t *)p;
  for (int r = 0; r < j->rounds; r++) j->failures += golden_run(j->g, j->name, 0) != 0;
  return NULL;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: %s a.golden b.golden\n", argv[0]); return 2; }
  golden_t ga, gb;
  if (golden_load(argv[1], &ga) || golden_load(argv[2], &gb)) { fprintf(stderr, "cannot read traces\n"); return 2; }
  job_t a = {&ga, argv[1], 200, 0}, b = {&gb, argv[2], 200, 0};
  pthread_t ta, tb;
  pthread_create(&ta, NULL, worker, &a);
  pthread_create(&tb, NULL, worker, &b);
  pthread_join(ta, NULL);
  pthread_join(tb, NULL);
  printf("threads: %d failures in %d concurrent runs\n", a.failures + b.failures, a.rounds + b.rounds);
  golden_free(&ga); golden_free(&gb);
  return (a.failures + b.failures) ? 1 : 0;
}
