# AgentLean for Swift

Swift binding of agent.lean over its C ABI ([`c/agent.h`](../../c/agent.h)), through Swift's
native C interop. The agent core is pure: it never does I/O, never starts threads and never sees
an API key. Your app feeds it events, performs the effects it asks for (model requests, tool
calls) and feeds the results back.

## Install

1. Build the C library for Apple platforms (needs Xcode and CMake; a few minutes from scratch):

   ```sh
   python3 scripts/bundle.py            # if bundle/out does not exist yet
   scripts/build_xcframework.sh         # -> bindings/swift/AgentLeanC.xcframework
   ```

   The XCFramework has static slices for macOS (arm64, x86_64), iOS (arm64), the iOS simulator
   (arm64, x86_64) and Mac Catalyst (arm64, x86_64). `SLICES="ios ios-simulator"` builds a subset;
   `MACOS_ARCHS=arm64 SIM_ARCHS=arm64 CATALYST_ARCHS=arm64` skips x86_64.

2. Add the package: in Xcode, *File > Add Package Dependencies > Add Local...* and choose
   `bindings/swift`; or in a `Package.swift`:

   ```swift
   .package(path: "../agent-lean/bindings/swift"),
   // ...
   .target(name: "App", dependencies: [.product(name: "AgentLean", package: "swift")]),
   ```

   The package links `libc++` (the Lean runtime inside is C++20).

For fast macOS iteration without the XCFramework, the package falls back to the host build of the
bundle (`cmake -S bundle/out -B build/host && cmake --build build/host -j 12`) when
`AgentLeanC.xcframework` is missing or `AGENTLEAN_LINK=host` is set. That mode uses an unsafe
linker flag, so it only works when this package is the root package (e.g. `swift test`).

## Create an agent and drive the loop

```swift
import AgentLean

let agent = try Agent(config: [
  "agent": "assistant",
  "model": "gpt-4.1-mini",
  "endpoint": "https://api.openai.com/v1/chat/completions",
])

try agent.feed(.user(text: "add 2 and 3"))
while let effect = try agent.nextTypedEffect() {
  switch effect {
  case .llmRequest(let req):   // POST req.body to req.url; feed .llmResponse / .llmChunk+.llmEnd / .llmError
    break
  case .toolCall(let call):    // run call.name / call.hostID; feed .toolResult or .toolError
    break
  case .ui(let ui):            // text deltas, tool start/end: display only
    break
  case .complete(let done):    // done.reason == "final" -> done.answer
    break
  case .unknown:
    break
  }
}
```

`feed` returns `.ok`, `.invalid(message)` or `.rejected(message)`; the last two leave the state
unchanged. The raw API (`feed(_: Data)`, `nextEffect() -> Data?`, `effects() -> [Data]`) passes the
ABI's JSON bytes through unchanged. `snapshot()` / `Agent(snapshot:)` + `.resume` persist and
resume a run; `trace()`, `audit()` (sensitive payloads hashed) and `traceLength` expose the
event-sourced trace. `isSensitive` turns true once output of a sensitive tool entered the run:
encrypt the trace at rest. `isDone` turns true when the run ended for good (error, policy halt,
budget, cancel); a `final` answer leaves the agent ready for the next user turn.

## Async driver

```swift
let transport = Agent.urlSessionTransport { credentialName in
  try Keychain.read(credentialName)          // your code: the secret for "openai", "anthropic", ...
}
let answer = try await agent.run(
  user: "what's on example.com?",
  transport: transport,
  tools: ["net.fetch": { call in .string(try await fetchText(call.args["url"]?.stringValue)) }],
  onUI: { ui in print(ui) }
)
```

`run` drives one turn to completion: requests and tool calls issued together run concurrently, and
their results are fed back one at a time. Tools are looked up by the call's `hostID`, then its
`name`; a missing handler or a thrown error is reported to the agent as a tool error. A transport
error becomes `llm_error`. A run ending other than `final` throws `AgentError.runEnded(completion)`;
`drive(_:transport:tools:onUI:)` returns the `Completion` instead (pass `.resume` after a restore).
Cancelling the task feeds `cancel` and throws `CancellationError`. A transport is any
`@Sendable (LLMRequest) async throws -> LLMResponse`, so tests can script responses without a network.

## Threading

A C handle may be used from any thread, but by one thread at a time. `Agent` enforces this with an
internal lock, so it is `Sendable` and can be shared between tasks; each call is short and
non-blocking. Distinct agents are independent handles.

## Credentials

Model-request effects carry only the *name* of a credential (`credential`, e.g. `openai`) and the
scheme to inject it with (`auth`: `bearer` or `x-api-key`). The core, its trace and its snapshots
never contain a key. Your transport looks the secret up (Keychain, server-issued token, ...) and
adds it to the request; `LLMRequest.urlRequest(secret:)` places it in the right header. The
binding keeps no copy.

## Tests

```sh
cd bindings/swift && swift test
```

The suite replays every `traces/*.golden` through the Swift API and requires byte-identical
effects, and drives the async loop against a scripted fake transport.
