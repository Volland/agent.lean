## Purpose

The portable build turns the Lean library into plain sources that compile with stock toolchains for embedded Linux and mobile, and holds the budgets that keep it small, fast and fully proven.

## ADDED Requirements

### Requirement: Source bundle
The project SHALL produce a self-contained source bundle that builds the library with a standard C/C++ toolchain and no Lean installation.

#### Scenario: Build without Lean
- **WHEN** the bundle is built on a machine with only a C/C++ compiler and CMake
- **THEN** it produces a static library and the reference example agent

### Requirement: Target matrix
The bundle SHALL build and pass the conformance suite for Linux on x86_64, aarch64, armv7 and riscv64, for iOS (device and simulator), for Android (arm64-v8a and x86_64) and for macOS.

#### Scenario: Every target passes conformance
- **WHEN** continuous integration runs
- **THEN** each target in the matrix builds and passes the golden-trace conformance suite

### Requirement: Cross-platform conformance
Every target SHALL produce byte-identical effects and traces for the same golden inputs.

#### Scenario: Golden trace identical across targets
- **WHEN** a golden trace is replayed on two different targets
- **THEN** the emitted effects are byte-identical

### Requirement: Runtime import allowlist
Runtime modules SHALL import only the Lean core prelude and an explicit allowlist of standard-library modules, and the build SHALL fail otherwise.

#### Scenario: Forbidden import fails build
- **WHEN** a runtime module transitively imports a module outside the allowlist
- **THEN** the build fails and names the import chain

### Requirement: Binary size budget
The stripped, statically linked reference agent SHALL stay within the size budget set by the feasibility spike, and continuous integration SHALL fail on a regression beyond the allowed margin.

#### Scenario: Size regression fails CI
- **WHEN** a change grows the reference agent beyond its budget
- **THEN** the size check fails and reports the growth

### Requirement: Performance budgets
Step overhead, codec throughput, cold start and memory per agent SHALL be measured on every target class, and continuous integration SHALL fail on a regression beyond the allowed margin.

#### Scenario: Step overhead regression fails CI
- **WHEN** a change raises the measured step overhead beyond the allowed margin
- **THEN** the benchmark check fails and reports the regression

### Requirement: Runtime surface manifest
The set of Lean runtime symbols the bundle links SHALL be recorded in a manifest, and the build SHALL fail when the set changes without the manifest being updated.

#### Scenario: New runtime symbol fails CI
- **WHEN** a change makes the bundle link a runtime symbol not in the manifest
- **THEN** the manifest check fails and names the symbol

### Requirement: No unproven runtime code
Runtime and theorem modules SHALL contain no `sorry` and rely on no axioms beyond Lean's standard ones.

#### Scenario: sorry fails build
- **WHEN** a runtime or theorem module contains `sorry`
- **THEN** the build fails and names the declaration
