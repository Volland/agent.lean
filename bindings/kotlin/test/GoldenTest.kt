// Conformance test for the Kotlin binding, runnable without Gradle (see ../run_tests.sh):
//   java -Dagentlean.jni.path=<libagentlean_jni> -cp <test.jar> GoldenTestKt <traces dir>
// Exits non-zero on any failure.
import dev.agentlean.Agent
import dev.agentlean.AgentException
import dev.agentlean.Effect
import dev.agentlean.Events
import dev.agentlean.FeedResult
import dev.agentlean.Json
import dev.agentlean.LlmReply
import dev.agentlean.run
import java.io.File
import java.util.Base64
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import kotlin.system.exitProcess

private var failures = 0
private var passes = 0

private fun ok(name: String) { passes++; println("  ok    $name") }
private fun fail(name: String, why: String) { failures++; println("  FAIL  $name: $why") }

/** Non-empty lines of a golden file, as raw bytes (no decoding) and as text. */
private class Golden(val name: String, val raw: List<ByteArray>) {
    val lines: List<String> = raw.map { String(it, Charsets.UTF_8) }
    val config: String get() = lines[0].removePrefix("C ")
    val events: List<String> get() = lines.filter { it.startsWith("E ") }.map { it.substring(2) }

    companion object {
        fun load(f: File): Golden {
            val bytes = f.readBytes()
            val out = ArrayList<ByteArray>()
            var start = 0
            for (i in 0..bytes.size) {
                if (i == bytes.size || bytes[i] == '\n'.code.toByte()) {
                    if (i > start) out.add(bytes.copyOfRange(start, i))
                    start = i + 1
                }
            }
            return Golden(f.nameWithoutExtension, out)
        }
    }
}

/**
 * Replay every E line through the Kotlin API and require exactly the X lines that follow it, byte
 * for byte, in order. Returns null on success or a description of the first difference.
 */
// @tg: verifies:: [[openspec:host-abi#Native bindings#Golden trace through bindings]] {level: e2e}
private fun replayGolden(g: Golden): String? {
    if (g.lines.isEmpty() || !g.lines[0].startsWith("C ")) return "no config line"
    Agent(g.config).use { a ->
        var i = 1
        while (i < g.raw.size) {
            val line = g.lines[i]
            if (!line.startsWith("E ")) return "line ${i + 1}: expected an event line"
            val event = g.raw[i].copyOfRange(2, g.raw[i].size)
            val r = a.feed(event)
            if (r != FeedResult.Ok) return "line ${i + 1}: event not accepted: $r"
            i++
            while (true) {
                val eff = a.nextEffectBytes() ?: break
                if (i >= g.raw.size || !g.lines[i].startsWith("X ")) {
                    return "line ${i + 1}: unexpected extra effect ${String(eff, Charsets.UTF_8)}"
                }
                val want = g.raw[i].copyOfRange(2, g.raw[i].size)
                if (!want.contentEquals(eff)) {
                    return "line ${i + 1}: effect differs\n    want ${g.lines[i].substring(2)}\n    got  ${String(eff, Charsets.UTF_8)}"
                }
                Effect.parse(String(eff, Charsets.UTF_8)) // every golden effect must parse
                i++
            }
            if (i < g.raw.size && g.lines[i].startsWith("X ")) return "line ${i + 1}: missing effect ${g.lines[i].substring(2)}"
        }
        // The String API must agree with the byte API.
        Agent(g.config).use { b ->
            val got = ArrayList<String>()
            for (e in g.events) { b.feed(e); got.addAll(b.effects()) }
            val want = g.lines.filter { it.startsWith("X ") }.map { it.substring(2) }
            if (got != want) return "String API effects differ from the golden"
            if (b.trace() != a.trace()) return "traces differ between two replays"
        }
    }
    return null
}

/** Drive a golden run through Agent.run with a scripted transport and tools, keyed by request/tool id. */
private fun driveGolden(g: Golden): String? {
    val llm = LinkedHashMap<String, MutableList<String>>()
    val toolResults = HashMap<String, String>()
    for (e in g.events) {
        val m = Json.members(e)
        val type = Json.parse(m["type"]!!) as String
        val id = m["id"]?.let { Json.parse(it) as String } ?: continue
        when (type) {
            "llm_response", "llm_chunk" -> llm.getOrPut(id) { ArrayList() }.add(e)
            "tool_result" -> toolResults[id] = m["result"]!!
        }
    }
    val user = Json.parse(Json.members(g.events[0])["text"]!!) as String
    val ui = ArrayList<String>()
    val complete = Agent(g.config).use { a ->
        a.run(
            user,
            transport = { req ->
                val evs = llm[req.id] ?: error("no scripted response for ${req.id}")
                val first = Json.parse(evs[0]) as Map<*, *>
                if (first["type"] == "llm_response") {
                    LlmReply.Response((first["status"] as Long).toInt(), first["body"] as String)
                } else {
                    LlmReply.Stream(evs.map { Base64.getDecoder().decode((Json.parse(it) as Map<*, *>)["b64"] as String) })
                }
            },
            tools = { call -> toolResults[call.id] ?: error("no scripted result for ${call.id}") },
            onUi = { ui.add(it.json) },
        )
    }
    val want = g.lines.last { it.startsWith("X ") }.substring(2)
    if (complete.json != want) return "complete differs\n    want $want\n    got  ${complete.json}"
    val wantUi = g.lines.filter { it.startsWith("X ") && it.contains("\"type\":\"ui\"") }.map { it.substring(2) }
    if (ui.sorted() != wantUi.sorted()) return "ui effects differ: $ui"
    return null
}

private fun check(name: String, body: () -> String?) {
    val why = try { body() } catch (t: Throwable) { "threw $t" }
    if (why == null) ok(name) else fail(name, why)
}

fun main(args: Array<String>) {
    val dir = File(args.firstOrNull() ?: "traces")
    val files = dir.listFiles { f -> f.name.endsWith(".golden") }?.sortedBy { it.name }.orEmpty()
    if (files.isEmpty()) { println("no golden traces in ${dir.absolutePath}"); exitProcess(2) }
    val goldens = files.map(Golden::load)

    println("golden replay (${goldens.size} traces):")
    for (g in goldens) check("golden ${g.name}") { replayGolden(g) }

    println("driver:")
    for (n in listOf("basic", "anthropic", "errors", "policy-halt", "policy-refusal", "streaming", "agent-as-tool", "tools-parallel-sensitive")) {
        val g = goldens.find { it.name == n } ?: continue
        check("run() $n") { driveGolden(g) }
    }

    val basic = goldens.first { it.name == "basic" }
    println("api:")
    check("invalid event leaves state unchanged") {
        Agent(basic.config).use { a ->
            val before = a.snapshot()
            val r = a.feed("{not json")
            when {
                r !is FeedResult.Invalid -> "expected Invalid, got $r"
                r.message.isEmpty() -> "Invalid without a message"
                a.snapshot() != before -> "snapshot changed"
                else -> null
            }
        }
    }
    check("unexpected event is rejected") {
        Agent(basic.config).use { a ->
            val r = a.feed(Events.llmResponse("r9", 200, "{}"))
            if (r is FeedResult.Rejected || r is FeedResult.Invalid) null else "expected Rejected, got $r"
        }
    }
    check("bad config throws AgentException with message") {
        try { Agent("""{"agent":"no-such-agent","model":"m","endpoint":"e"}""").close(); "no exception" }
        catch (e: AgentException) { if (e.message.isNullOrEmpty()) "empty message" else null }
    }
    check("non-BMP text survives JNI (UTF-8, not modified UTF-8)") {
        val text = "emoji 😀 clef 𝄞 ü NUL-free"
        Agent(basic.config).use { a ->
            a.feed(Events.user(text))
            val eff = a.effects().joinToString("\n")
            val trace = a.trace()
            when {
                !eff.contains("😀") || !eff.contains("𝄞") -> "effect lost the characters: ${eff.take(300)}"
                !trace.contains("😀") -> "trace lost the characters: ${trace.take(300)}"
                else -> null
            }
        }
    }
    check("snapshot / restore round trip, resume re-issues the request") {
        // restore() rebuilds the run state; the trace is not in the snapshot (the host keeps it).
        Agent(basic.config).use { a ->
            a.feed(basic.events[0]); a.effects() // an llm_request is now in flight
            val snap = a.snapshot()
            Agent.restore(snap).use { b ->
                val restoredRun = Json.members(b.snapshot())["run"]
                val restoredLen = b.traceLength
                val re = if (b.feed(Events.resume()) == FeedResult.Ok) b.effects() else null
                when {
                    restoredRun != Json.members(snap)["run"] -> "restored run state differs"
                    restoredLen != 0L -> "restored trace should start empty, has $restoredLen"
                    re == null -> "resume not accepted: ${b.lastError()}"
                    re.map(Effect::parse).none { it is Effect.LlmRequest } -> "resume did not re-issue the model request: $re"
                    else -> null
                }
            }
        }
    }
    check("isDone after policy halt and cancel") {
        val g = goldens.first { it.name == "policy-halt" }
        Agent(g.config).use { a ->
            for (e in g.events) { a.feed(e); a.effects() }
            if (!a.isDone) return@use "not done after policy halt"
            Agent(basic.config).use { c ->
                if (c.isDone) "done before any event"
                else if (c.feed(Events.cancel()) != FeedResult.Ok || !c.isDone) "not done after cancel"
                else null
            }
        }
    }
    check("isSensitive, and audit hashes the sensitive payload") {
        val g = goldens.first { it.name == "tools-parallel-sensitive" }
        Agent(g.config).use { a ->
            for (e in g.events) { a.feed(e); a.effects() }
            when {
                !a.isSensitive -> "not sensitive after a sensitive tool result"
                !a.trace().contains("TX-SECRET-1") -> "trace should keep the payload"
                a.audit().contains("TX-SECRET-1") -> "audit leaks the sensitive payload"
                else -> null
            }
        }
    }
    check("closed agent throws, close is idempotent") {
        val a = Agent(basic.config)
        a.close(); a.close()
        try { a.snapshot(); "no exception after close" } catch (e: AgentException) { null }
    }
    val mode = if (Agent.parallelAgents) "parallel (per-agent lock)" else "serialized (process-wide lock)"
    check("agents on separate threads are independent, $mode") {
        val pool = Executors.newFixedThreadPool(4)
        try {
            val jobs = (0 until 64).map { k -> pool.submit(Callable { replayGolden(goldens[k % goldens.size]) }) }
            jobs.mapNotNull { it.get() }.firstOrNull()
        } finally { pool.shutdown() }
    }
    check("one agent shared across threads (synchronized)") {
        Agent(basic.config).use { a ->
            val pool = Executors.newFixedThreadPool(4)
            try {
                (0 until 200).map { pool.submit { a.snapshot(); a.traceLength; a.isDone } }.forEach { it.get() }
            } finally { pool.shutdown() }
            null
        }
    }

    println("${passes} passed, ${failures} failed")
    exitProcess(if (failures == 0) 0 else 1)
}
