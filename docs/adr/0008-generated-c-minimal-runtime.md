---
status: accepted
date: 2026-11-06
decision-makers: [Volodymyr Pavlyshyn]
---
# Generated C plus a minimal C++ runtime in v1; a pure-C runtime is the v2 track

## Context and Problem Statement

Lean emits C for every module, but its runtime (`src/runtime`) is C++ and the toolchain ships no prebuilt libraries for iOS, Android, armv7 or riscv64. "Cross-compile to pure C" is the goal; what do we accept in v1?

## Considered Options

* Ship generated C plus the pinned Lean runtime sources as a self-contained bundle, and keep our use of the runtime minimal and recorded
* Write a pure-C replacement runtime before v1

## Decision Outcome

Chosen option: "generated C plus a minimal runtime", because a replacement runtime is a large, risky project that would block everything else. Small and portable stays the overriding value: the toolchain is pinned exactly, the bundle contains only the Init/Std modules the library transitively needs, a manifest of every linked `lean_*` symbol is checked in CI, runtime code uses no `Task`, `IO.asTask` or threads, and data paths use fixed-width integers so bignum code stays off them. A pure-C mini-runtime that implements exactly the manifest is the planned v2 track and the route to RTOS/MCU targets.

### Consequences

* Good, because v1 is reachable with stock clang, the NDK and Xcode.
* Bad, because v1 links libc++/libstdc++.
* Risk, because cross-compiling the runtime for mobile is unproven; the week-one feasibility spike decides it.

## More Information

Capability `openspec:portable-build`.
