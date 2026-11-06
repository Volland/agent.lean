---
type: Constraint
source: "Lean 4 toolchain, target platforms (iOS, Android, embedded Linux), licences and the LLM threat model; each section names its own source"
---
# Constraints

Rules agent.lean must respect but did not choose: properties of the Lean toolchain, of the target platforms, of licences and of language models.

## Lean runtime is C++

Lean emits C for every module, but its runtime (`src/runtime`) is C++, so a build links libc++ or libstdc++. Source: the Lean 4 toolchain.

- constrains:: [[decisions#Generated C plus minimal runtime]] {strength: must, source: "Lean 4 runtime sources"}

## No prebuilt Lean libraries for mobile and embedded

The Lean toolchain ships compiled runtime and Init/Std libraries only for desktop hosts, not for iOS, Android, armv7 or riscv64. Source: Lean release artifacts.

- constrains:: [[decisions#Generated C plus minimal runtime]] {strength: must, source: "Lean release artifacts"}

## Lean runtime ABI is not stable

`lean.h` and the runtime change between Lean versions, so generated C must be compiled against the runtime of the exact toolchain that produced it. Source: the Lean 4 toolchain.

- constrains:: [[decisions#Generated C plus minimal runtime]] {strength: must, source: "Lean 4 toolchain"}

## Importing Lean links the compiler

Any runtime module that imports `Lean` (as `Lean.Data.Json` requires) links large parts of the Lean compiler into the binary. Source: Lean 4 library structure.

- constrains:: [[decisions#Runtime dependency budget]] {strength: must, source: "Lean 4 library structure"}

## Foreign threads must register with the Lean runtime

A thread not created by Lean must call `lean_initialize_thread` before touching Lean objects, which clashes with Swift and JVM thread pools. Source: `lean.h`.

- constrains:: [[decisions#Pull-based C ABI]] {strength: must, source: "lean.h"}
- constrains:: [[decisions#Pure step machine core]] {strength: should, source: "lean.h"}

## Lean has no HTTP or TLS client

The Lean standard library offers no HTTP or TLS client, so a Lean-native driver needs a C library for networking. Source: Lean 4 standard library.

- constrains:: [[decisions#Pull-based C ABI]] {strength: must, source: "Lean 4 standard library"}

## iOS forbids background daemons

An iOS app cannot run a separate long-lived server process, so local inference must run inside the app's process. Source: Apple iOS platform rules.

- constrains:: [[decisions#Local inference via in-process adapter]] {strength: must, source: "Apple iOS platform"}
- constrains:: [[decisions#Pure step machine core]] {strength: should, source: "Apple iOS platform"}

## Mobile operating systems terminate apps

iOS and Android may suspend or kill an app at any time, so a run must survive process death and resume. Source: iOS and Android app lifecycles.

- constrains:: [[decisions#Event-sourced trace]] {strength: must, source: "iOS and Android app lifecycle"}

## Android has no Panama FFM

The Android runtime does not support the JVM's Foreign Function and Memory API, so JNI is Android's native FFI. Source: Android runtime.

- constrains:: [[decisions#Pull-based C ABI]] {strength: must, source: "Android runtime"}

## GMP is LGPL

The GNU MP library, which Lean can use for big integers, is LGPL; static linking into closed mobile apps brings relinking obligations. Source: LGPL-3.0.

- constrains:: [[decisions#Runtime dependency budget]] {strength: must, source: "LGPL-3.0"}
- constrains:: [[decisions#Apache-2.0 licence and naming]] {strength: should, source: "LGPL-3.0"}

## Embedded memory and flash are scarce

Target boards and phones limit binary size and resident memory, so every linked module and runtime feature has a cost. Source: target hardware.

- constrains:: [[decisions#Runtime dependency budget]] {strength: must, source: "target hardware"}
- constrains:: [[decisions#Generated C plus minimal runtime]] {strength: must, source: "target hardware"}

## Model output is untrusted

Model responses and tool output can be malformed or adversarial (prompt injection), so nothing they contain may be trusted before decoding and policy checks. Source: LLM threat model.

- constrains:: [[decisions#Lean owns the LLM wire format]] {strength: must, source: "LLM threat model"}
- constrains:: [[decisions#Tools declared at compile time]] {strength: must, source: "LLM threat model"}
- constrains:: [[decisions#Policies compiled to monitors]] {strength: must, source: "LLM threat model"}
- constrains:: [[decisions#Credentials by reference]] {strength: must, source: "LLM threat model"}
