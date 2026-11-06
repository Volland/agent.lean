/* N threads, distinct handles, all golden traces concurrently (contributed by the Kotlin binding work).
 * @tg: verifies:: [[openspec:host-abi#Handle thread confinement#Two agents on two threads]] {level: integration} */
#include "golden.h"
#include <pthread.h>
static golden_t gs[8]; static int ng;
static void *worker(void *p) { long k = (long)p; int f = 0; for (int r = 0; r < 50; r++) f += golden_run(&gs[(k + r) % ng], "g", 0) != 0; return (void *)(long)f; }
int main(int argc, char **argv) {
  ng = argc - 1; for (int i = 0; i < ng; i++) golden_load(argv[i + 1], &gs[i]);
  int nt = 4; pthread_t t[16]; long fails = 0;
  for (long i = 0; i < nt; i++) pthread_create(&t[i], NULL, worker, (void *)i);
  for (int i = 0; i < nt; i++) { void *r; pthread_join(t[i], &r); fails += (long)r; }
  printf("mt: %ld failures; now main thread:\n", fails);
  for (int i = 0; i < ng; i++) fails += golden_run(&gs[i], "main", 0) != 0;
  printf("after: %ld failures\n", fails); return fails != 0;
}
