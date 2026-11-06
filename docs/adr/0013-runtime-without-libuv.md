---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# The bundled Lean runtime has no libuv, OpenSSL, GMP or mimalloc

## Context and Problem Statement

The feasibility spike found that the Lean 4.35 runtime links libuv (event loop, sockets, file metadata), OpenSSL, GMP and mimalloc. None of them is needed by an agent core that does no IO, and each one adds size, a cross-compilation step per target and, for GMP, LGPL obligations.

## Considered Options

* Compile the pinned runtime without them: drop `uv/*`, `openssl.cpp` and `mimalloc.cpp`, replace `libuv.cpp`/`libuv.h` with a stub overlay, give `io.cpp` a POSIX stand-in for the dozen libuv calls it makes, and use Lean's own bignums
* Vendor and cross-compile libuv, OpenSSL and GMP for every target

## Decision Outcome

Chosen option: "compile without them", because the shim is about 150 lines of POSIX and the result builds unchanged for macOS, iOS, Android and Linux on four architectures. Source patches to the pinned runtime are exact string replacements that make the bundle fail if they stop applying (one patch so far: iOS has no `system()`).

### Consequences

* Good, because the reference agent is 0.97 MB stripped on macOS and 0.9–1.7 MB fully static on Linux, with no LGPL code.
* Good, because the bundle needs only a C/C++20 compiler and CMake.
* Bad, because the system allocator replaces mimalloc: allocation dominates step time (about 40 µs on Apple M-series), a cost to revisit with an optional vendored mimalloc.
* Bad, because Lean code that uses `Std.Internal.UV` (async IO) cannot be bundled; the import allowlist already forbids it.

## More Information

Capability `openspec:portable-build`. Implemented in `scripts/bundle.py` and `bundle/shim/`.
