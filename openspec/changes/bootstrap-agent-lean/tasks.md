## 1. Feasibility spike (week one, go/no-go gate)

- [ ] 1.1 Write a hello-agent in Lean that imports only `Init` and runs one `step` over a hard-coded event
- [ ] 1.2 Extract its generated C plus the needed `Init` modules and the pinned runtime sources into a CMake tree
- [ ] 1.3 Cross-compile and run it on aarch64-linux-musl (static, stripped) and record size, cold start and RSS
- [ ] 1.4 Cross-compile and run it on iOS arm64 (device or simulator) inside a minimal Swift app
- [ ] 1.5 Cross-compile and run it on Android arm64-v8a inside a minimal JNI app
- [ ] 1.6 Audit GMP linkage of the release toolchain per platform; build the runtime without GMP for mobile if needed
- [ ] 1.7 Dump the linked `lean_*` symbols into a first runtime-surface manifest
- [ ] 1.8 Record the measured floors and set the size, cold-start and memory budgets; write the go/no-go result into `tg.md/decisions.md`

## 2. Project skeleton and guards

- [ ] 2.1 Create `lakefile.lean`, pin `lean-toolchain`, add `AgentLean` (runtime) and `AgentLean/Meta` (compile-time) libraries
- [ ] 2.2 Add the runtime import-allowlist check that fails the build with the import chain
- [ ] 2.3 Add the no-`sorry` / standard-axioms check for runtime and theorem modules
- [ ] 2.4 Set up CI running `lake build`, the guards, `tg check` and `openspec validate`

## 3. JSON and SSE codecs

- [ ] 3.1 Implement a minimal JSON value type, parser and printer over `ByteArray`
- [ ] 3.2 Prove print-then-parse round-trip and that parse failure never yields a value
- [ ] 3.3 Implement an incremental SSE decoder and prove chunk-split invariance
- [ ] 3.4 Add Plausible property tests for both codecs

## 4. Agent core

- [ ] 4.1 Define `State`, `Event`, `Effect`, `Config` and `step` with `@tg: implements:: [[openspec:agent-core#Pure step function]]`
- [ ] 4.2 Implement the ReAct loop with final answer, cancellation and completion effects
- [ ] 4.3 Implement run budgets and prove termination within the step budget
- [ ] 4.4 Implement parallel tool calls matched by call id
- [ ] 4.5 Implement UI events for text deltas and tool start/end
- [ ] 4.6 Implement agent-as-tool and prove child budgets never exceed the parent's remaining budgets
- [ ] 4.7 Implement the context window policy and prove pinned content is never dropped
- [ ] 4.8 Annotate each implementing declaration with `@tg: implements::` for its `agent-core` requirement

## 5. Tools

- [ ] 5.1 Define the `Tool` structure with executor, required `idempotent`, `untrusted` and `sensitive` labels
- [ ] 5.2 Implement `deriving ToolSchema` in `AgentLean.Meta` and prove schema acceptance matches decoding for the supported types
- [ ] 5.3 Implement typed argument decoding with unknown-tool and malformed-argument errors
- [ ] 5.4 Implement pure, io and host executors and the static tool registry
- [ ] 5.5 Implement precondition and postcondition checks
- [ ] 5.6 Implement resume handling of in-flight calls by idempotency
- [ ] 5.7 Annotate each implementing declaration with `@tg: implements::` for its `tools` requirement

## 6. Policies

- [ ] 6.1 Define the L1/L2 policy AST and its semantics over traces
- [ ] 6.2 Implement the `policy` syntax in `AgentLean.Meta`
- [ ] 6.3 Compile policies to monitors and prove monitor soundness
- [ ] 6.4 Implement recoverable refusals and `halt` violations
- [ ] 6.5 Implement taint predicates over untrusted labels
- [ ] 6.6 Annotate each implementing declaration with `@tg: implements::` for its `policies` requirement

## 7. LLM codecs

- [ ] 7.1 Implement the OpenAI-compatible Chat Completions request encoder and response/stream decoder
- [ ] 7.2 Implement the Anthropic Messages encoder and response/stream decoder
- [ ] 7.3 Map undecodable bytes to decode-error events
- [ ] 7.4 Annotate each implementing declaration with `@tg: implements::` for its `llm-codecs` requirement

## 8. Trace and replay

- [ ] 8.1 Define the versioned trace and snapshot formats
- [ ] 8.2 Implement replay and prove determinism and snapshot/resume equivalence
- [ ] 8.3 Implement sensitive-trace flagging and audit export with hashes
- [ ] 8.4 Add the first golden traces under `traces/`
- [ ] 8.5 Annotate each implementing declaration with `@tg: implements::` for its `trace-replay` requirement

## 9. Host ABI and Lean driver

- [ ] 9.1 Write `c/agent.h` and the C shim over the Lean exports (`agent_new`, `agent_feed`, `agent_next_effect`, `agent_snapshot`, `agent_free`)
- [ ] 9.2 Implement error codes for invalid payloads with state left unchanged
- [ ] 9.3 Implement `credential_ref` and the non-serializable `Secret` type
- [ ] 9.4 Implement the reference C driver and `AgentLean.Driver` over libcurl
- [ ] 9.5 Annotate each implementing declaration with `@tg: implements::` for its `host-abi` requirement

## 10. Local inference adapter

- [ ] 10.1 Implement `c/agent_llama.c` over llama.cpp behind the transport interface
- [ ] 10.2 Pass derived tool schemas as decoding grammars
- [ ] 10.3 Add the transport-neutrality test (same trace via HTTP mock and local adapter)

## 11. Bundle, targets and budgets

- [ ] 11.1 Implement `lake run bundle` producing the self-contained source tree with tree-shaken `Init`/`Std`
- [ ] 11.2 Add CMake toolchain files for every target in the matrix
- [ ] 11.3 Add the CI matrix building every target and running the conformance suite
- [ ] 11.4 Add size, step-overhead, codec-throughput, cold-start and memory benchmarks with regression gates
- [ ] 11.5 Add the runtime-surface manifest check
- [ ] 11.6 Add comparison benchmarks against agent.cpp and agent.rs for step overhead, cold start and size

## 12. Native bindings

- [ ] 12.1 Build the Swift package (XCFramework, module map, `async` wrapper)
- [ ] 12.2 Build the Kotlin/Android AAR (JNI, coroutines wrapper) and KMP iOS cinterop
- [ ] 12.3 Run the golden traces through both bindings in CI

## 13. Traceability

- [ ] 13.1 Annotate each test with `@tg: verifies:: [[openspec:<capability>#<Requirement>#<Scenario>]]` for the scenario it proves
- [ ] 13.2 Keep `tg.md/decisions.md` and `tg.md/constraints.md` in sync with the ADRs and record new decisions as typed sections
- [ ] 13.3 Keep `tg.md/architecture.md` explaining every capability and listing it in its `openspec:` frontmatter
- [ ] 13.4 Run `tg check`, `tg ontology check` and `tg trace agent-core tools policies llm-codecs trace-replay host-abi portable-build --gaps` and close every gap
