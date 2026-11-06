/* agent.lean overlay: replaces runtime/libuv.h; the bundle has no libuv event loop. */
#pragma once
#include <lean/lean.h>
namespace lean {
extern "C" void initialize_libuv();
extern "C" LEAN_EXPORT char ** lean_setup_args(int argc, char ** argv);
extern "C" LEAN_EXPORT lean_obj_res lean_libuv_version(lean_obj_arg);
}
