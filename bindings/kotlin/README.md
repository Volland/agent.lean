# agent.lean for Kotlin (Android and desktop JVM)

A thin binding over the C ABI in `c/agent.h`: hand-written JNI glue (`jni/agent_jni.c`) plus the
`dev.agentlean` Kotlin package. Payloads cross JNI as UTF-8 byte arrays, so any Unicode text
(including emoji and other non-BMP characters) reaches the core unchanged. No Gradle is needed.

## Android

```sh
scripts/build_android.sh          # -> build/android/agentlean.aar (arm64-v8a, x86_64)
```

The AAR holds `classes.jar` (Java 8 bytecode, no Android API used), `jni/<abi>/libagentlean_jni.so`
(libc++ linked statically, 16 KB page aligned, only the JNI functions exported), consumer R8
rules and a manifest with `minSdkVersion 24`. Add it to an app with
`implementation(files("libs/agentlean.aar"))`; the app supplies `kotlin-stdlib`.
`System.loadLibrary("agentlean_jni")` runs on first use of `Agent` (or call `NativeLoader.load()`).

## Desktop JVM

```sh
bindings/kotlin/run_tests.sh      # builds libagentlean_jni for the host, runs the conformance test
```

Load the library from `java.library.path`, or name the file with
`-Dagentlean.jni.path=/abs/path/libagentlean_jni.dylib`.

## Driving an agent

The host feeds events and pulls effects; the library never calls back and never starts threads.

```kotlin
Agent("""{"agent":"assistant","model":"gpt-4.1-mini","endpoint":"https://api.openai.com/v1/chat/completions"}""").use { agent ->
    agent.feed(Events.user("hello"))
    while (true) {
        val json = agent.nextEffect() ?: break          // or agent.effects() for all pending
        when (val e = Effect.parse(json)) {
            is Effect.LlmRequest -> { /* POST e.body to e.url, then */ agent.feed(Events.llmResponse(e.id, status, body)) }
            is Effect.ToolCall   -> agent.feed(Events.toolResult(e.id, """{"ok":true}"""))
            is Effect.Ui         -> showProgress(e)
            is Effect.Complete   -> println(e.answer)
            is Effect.Unknown    -> {}
        }
    }
}
```

`feed` returns `FeedResult.Ok`, `Invalid(message)` or `Rejected(message)`; on the last two the state
is unchanged. `snapshot()` / `Agent.restore(snapshot)` (then feed `Events.resume()`) survive a process
death; the host keeps the trace (`trace()`, or `audit()` with sensitive payloads hashed; encrypt the
trace at rest when `isSensitive`). `isDone` turns true on terminal outcomes (error, policy halt,
cancel); a final answer leaves the run open for another user turn.

Or let the blocking driver do the loop:

```kotlin
val done: Effect.Complete = agent.run(
    user = "add 2 and 3",
    transport = { req -> LlmReply.Response(200, http.post(req.url, req.headers + req.authHeader(secrets[req.credential]), req.body)) },
    tools = { call -> myTools.invoke(call.name, call.argsJson) },   // returns a JSON value
    onUi = { ui -> render(ui) },
)
```

A throwing transport or tool is reported to the agent as `llm_error` / `tool_error`. For
`stream: true` requests return `LlmReply.Stream(chunks)`; text deltas reach `onUi` as each chunk
is fed. From a coroutine (no kotlinx-coroutines dependency in the binding):
`val done = withContext(Dispatchers.IO) { agent.run(text, transport, tools) }`.

## Credentials

Effects never carry a secret. An `llm_request` names the credential (`"credential":"openai"`) and
the header scheme (`"auth":"bearer"` or `"x-api-key"`); the host looks the secret up in its own
store (Android Keystore, environment, ...) and adds it with `req.authHeader(secret)`. Nothing the
core sees, logs, traces or snapshots contains the key.

## Threading

The C ABI allows one thread at a time per handle. Every `Agent` method takes a lock, so an agent
may be shared between threads; calls block briefly, so keep them off the Android main thread.
Locks are per agent, so distinct agents run in parallel (`-Dagentlean.parallel=false` or
`Agent.parallelAgents = false` serializes all agents behind one lock). Close agents (`use {}`) to
free native memory.
