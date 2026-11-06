## 1. Feasibility spike (week one, go/no-go gate)

- [x] 1.1 Write a hello-agent in Lean that imports only `Init` and runs one `step` over a hard-coded event
- [x] 1.2 Extract its generated C plus the needed `Init` modules and the pinned runtime sources into a CMake tree
- [x] 1.3 Cross-compile and run it on aarch64-linux-musl (static, stripped) and record size, cold start and RSS
- [x] 1.4 Cross-compile it for iOS arm64 (links) and run it as Mac Catalyst with the iOS SDK (no simulator runtime on the build machine)
- [x] 1.5 Cross-compile it for Android arm64-v8a and x86_64 (the conformance suite runs on the emulator in CI)
- [x] 1.6 Audit GMP linkage (the release links GMP statically) and build the runtime without GMP, libuv, OpenSSL and mimalloc on every target
- [x] 1.7 Dump the linked `lean_*` symbols into a first runtime-surface manifest
- [x] 1.8 Record the measured floors and set the size, cold-start and memory budgets; write the go/no-go result into `tg.md/decisions.md`

## 2. Project skeleton and guards

- [x] 2.1 Create `lakefile.lean`, pin `lean-toolchain`, add `AgentLean` (runtime) and `AgentLean/Meta` (compile-time) libraries
- [x] 2.2 Add the runtime import-allowlist check that fails the build with the import chain
- [x] 2.3 Add the no-`sorry` / standard-axioms check for runtime and theorem modules
- [x] 2.4 Set up CI running `lake build`, the guards, `tg check` and `openspec validate`

## 3. JSON and SSE codecs

- [x] 3.1 Implement a minimal JSON value type, parser and printer over `ByteArray`
- [x] 3.2 Test print-then-parse round-trip and rejection of malformed input (a formal round-trip proof is left for later; parse failure is an `Except.error` by type)
- [x] 3.3 Implement an incremental SSE decoder and prove chunk-split invariance
- [x] 3.4 Add generated-input property tests for both codecs (deterministic generators in `Tests/`, no Plausible dependency)

## 4. Agent core

- [x] 4.1 Define `State`, `Event`, `Effect`, `Config` and `step` with `@tg: implements:: [[openspec:agent-core#Pure step function]]`
- [x] 4.2 Implement the ReAct loop with final answer, cancellation and completion effects
- [x] 4.3 Implement run budgets and prove termination within the step budget
- [x] 4.4 Implement parallel tool calls matched by call id
- [x] 4.5 Implement UI events for text deltas and tool start/end
- [x] 4.6 Implement agent-as-tool and prove child budgets never exceed the parent's remaining budgets
- [x] 4.7 Implement the context window policy and prove pinned content is never dropped
- [x] 4.8 Annotate each implementing declaration with `@tg: implements::` for its `agent-core` requirement

## 5. Tools

- [x] 5.1 Define the `Tool` structure with executor, required `idempotent`, `untrusted` and `sensitive` labels
- [x] 5.2 Implement `deriving ToolSchema` in `AgentLean.Meta` and check schema acceptance against decoding on generated values
- [x] 5.3 Implement typed argument decoding with unknown-tool and malformed-argument errors
- [x] 5.4 Implement pure, io and host executors and the static tool registry
- [x] 5.5 Implement precondition and postcondition checks
- [x] 5.6 Implement resume handling of in-flight calls by idempotency
- [x] 5.7 Annotate each implementing declaration with `@tg: implements::` for its `tools` requirement

## 6. Policies

- [x] 6.1 Define the L1/L2 policy AST and its semantics over traces
- [x] 6.2 Implement the `policy` syntax in `AgentLean.Meta`
- [x] 6.3 Compile policies to monitors and prove monitor soundness
- [x] 6.4 Implement recoverable refusals and `halt` violations
- [x] 6.5 Implement taint predicates over untrusted labels
- [x] 6.6 Annotate each implementing declaration with `@tg: implements::` for its `policies` requirement

## 7. LLM codecs

- [x] 7.1 Implement the OpenAI-compatible Chat Completions request encoder and response/stream decoder
- [x] 7.2 Implement the Anthropic Messages encoder and response/stream decoder
- [x] 7.3 Map undecodable bytes to decode-error events
- [x] 7.4 Annotate each implementing declaration with `@tg: implements::` for its `llm-codecs` requirement

## 8. Trace and replay

- [x] 8.1 Define the versioned trace and snapshot formats
- [x] 8.2 Implement replay and prove determinism and snapshot/resume equivalence
- [x] 8.3 Implement sensitive-trace flagging and audit export with hashes
- [x] 8.4 Add the first golden traces under `traces/`
- [x] 8.5 Annotate each implementing declaration with `@tg: implements::` for its `trace-replay` requirement

## 9. Host ABI and Lean driver

- [x] 9.1 Write `c/agent.h` and the C shim over the Lean exports (`agent_new`, `agent_feed`, `agent_next_effect`, `agent_snapshot`, `agent_free`)
- [x] 9.2 Implement error codes for invalid payloads with state left unchanged
- [x] 9.3 Implement `credential_ref` and the non-serializable `Secret` type
- [x] 9.4 Implement the reference C driver and `AgentLean.Driver` over libcurl
- [x] 9.5 Annotate each implementing declaration with `@tg: implements::` for its `host-abi` requirement

## 10. Local inference adapter

- [x] 10.1 Implement `c/agent_llama.c` over llama.cpp behind the transport interface
- [x] 10.2 Pass derived tool schemas as decoding grammars
- [x] 10.3 Add the transport-neutrality test (same trace via HTTP mock and local adapter)

## 11. Bundle, targets and budgets

- [x] 11.1 Implement `lake run bundle` producing the self-contained source tree with tree-shaken `Init`/`Std`
- [x] 11.2 Add CMake toolchain files for every target in the matrix
- [x] 11.3 Add the CI matrix building every target and running the conformance suite
- [x] 11.4 Add size, step-overhead, codec-throughput, cold-start and memory benchmarks with regression gates
- [x] 11.5 Add the runtime-surface manifest check
- [ ] 11.6 Add comparison benchmarks against agent.cpp and agent.rs for step overhead, cold start and size (deferred: needs the exact projects to compare against)

## 12. Native bindings

- [x] 12.1 Build the Swift package (XCFramework, module map, `async` wrapper)
- [x] 12.2 Build the Kotlin/Android AAR (JNI, coroutines wrapper) and KMP iOS cinterop
- [x] 12.3 Run the golden traces through both bindings in CI

## 13. Traceability

- [x] 13.1 Annotate each test with `@tg: verifies:: [[openspec:<capability>#<Requirement>#<Scenario>]]` for the scenario it proves
- [x] 13.2 Keep `tg.md/decisions.md` and `tg.md/constraints.md` in sync with the ADRs and record new decisions as typed sections
- [x] 13.3 Keep `tg.md/architecture.md` explaining every capability and listing it in its `openspec:` frontmatter
- [x] 13.4 Run `tg check`, `tg ontology check` and `tg trace agent-core tools policies llm-codecs trace-replay host-abi portable-build --gaps` and close every gap
