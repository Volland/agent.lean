/* Cross-platform conformance: replay golden traces through the C ABI.
 * @tg: verifies:: [[openspec:host-abi#Pull-based driving#Host loop round trip]] {level: integration}
 * @tg: verifies:: [[openspec:portable-build#Cross-platform conformance#Golden trace identical across targets]] {level: e2e}
 * @tg: verifies:: [[openspec:portable-build#Target matrix#Every target passes conformance]] {level: e2e} */
#include "golden.h"

int main(int argc, char **argv) {
  if (argc < 2) { fprintf(stderr, "usage: %s traces/*.golden\n", argv[0]); return 2; }
  int failed = 0;
  for (int k = 1; k < argc; k++) {
    golden_t g;
    if (golden_load(argv[k], &g) != 0) { fprintf(stderr, "cannot read %s\n", argv[k]); failed++; continue; }
    failed += golden_run(&g, argv[k], 1) != 0;
    golden_free(&g);
  }
  printf("%d/%d golden traces reproduced\n", argc - 1 - failed, argc - 1);
  return failed ? 1 : 0;
}
