#include <lean/lean.h>
#include <stdio.h>
#include <time.h>
extern void lean_initialize_runtime_module(void);
extern lean_object* runtime_initialize_spike_Spike_Hello(uint8_t builtin);
extern lean_object* agentlean_spike_step(uint32_t n, lean_object* ev);
int main(void) {
  struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a);
  lean_initialize_runtime_module();
  lean_object* r = runtime_initialize_spike_Spike_Hello(1);
  if (lean_io_result_is_error(r)) { fprintf(stderr, "init failed\n"); return 1; }
  lean_dec_ref(r);
  lean_io_mark_end_initialization();
  clock_gettime(CLOCK_MONOTONIC, &b);
  lean_object* out = agentlean_spike_step(1, lean_mk_string("user_message"));
  printf("%s\n", lean_string_cstr(out));
  printf("cold_start_us=%ld\n", (b.tv_sec - a.tv_sec) * 1000000 + (b.tv_nsec - a.tv_nsec) / 1000);
  lean_dec_ref(out);
  return 0;
}
