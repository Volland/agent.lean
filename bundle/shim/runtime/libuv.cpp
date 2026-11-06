/* agent.lean overlay: replaces runtime/libuv.cpp; no event loop, sockets or timers. */
#include "runtime/libuv.h"
namespace lean {
extern "C" void initialize_libuv() {}
extern "C" LEAN_EXPORT char ** lean_setup_args(int, char ** argv) { return argv; }
extern "C" LEAN_EXPORT lean_obj_res lean_libuv_version(lean_obj_arg) { return lean_box(0); }
}
