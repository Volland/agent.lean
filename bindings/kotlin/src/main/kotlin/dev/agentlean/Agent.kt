package dev.agentlean

/** A failure reported by the native library (bad configuration or snapshot, failed feed, closed agent). */
class AgentException(message: String) : RuntimeException(message) {
    /** Used by the JNI glue: the message as UTF-8 bytes. */
    constructor(utf8: ByteArray) : this(String(utf8, Charsets.UTF_8))
}

/** Outcome of [Agent.feed]. On [Invalid] and [Rejected] the agent's state is unchanged. */
sealed class FeedResult(val code: Int) {
    val isOk: Boolean get() = this === Ok

    /** The event was accepted. */
    data object Ok : FeedResult(0)

    /** The bytes are not valid JSON or not a known event. */
    data class Invalid(val message: String) : FeedResult(1)

    /** The event is not expected in the current state. */
    data class Rejected(val message: String) : FeedResult(2)

    /** The call failed (out of memory, bad handle). */
    data object Failed : FeedResult(-1)
}

/**
 * One agent run, backed by a native `agent_t` handle.
 *
 * The host drives it: [feed] events, then pull effects with [nextEffect] / [effects] until none are
 * pending, perform them (HTTP with the credential the host injects, tools, UI) and feed the results
 * back. The library never calls host code and never starts threads.
 *
 * Threading: the C ABI allows one thread at a time per handle. Every method here holds a lock, so an
 * [Agent] may be shared between threads. Each agent has its own lock, so distinct agents run in
 * parallel; set the system property `agentlean.parallel=false` (or [parallelAgents]) to serialize
 * all agents behind one process-wide lock instead. Calls block the calling thread (they are CPU-bound and short); call them from
 * a background thread or `Dispatchers.Default`/`Dispatchers.IO`, not the Android main thread.
 *
 * Close the agent (or use `use {}`) to release native memory; the binding does not rely on GC.
 */
class Agent private constructor(private var handle: Long, private val lock: Any) : AutoCloseable {

    /** Create an agent from a run configuration, e.g. `{"agent":"assistant","model":"...","endpoint":"..."}`. */
    constructor(config: String) : this(config.toByteArray(Charsets.UTF_8), false)

    private constructor(input: ByteArray, restore: Boolean) : this(0L, newLock()) {
        handle = synchronized(lock) { if (restore) AgentNative.restore(input) else AgentNative.create(input) }
    }

    companion object {
        /** The C ABI version this binding speaks (AGENT_LEAN_ABI_VERSION). */
        const val ABI_VERSION = 1

        private val GLOBAL_LOCK = Any()

        /**
         * When true (the default), each agent has its own lock and distinct agents run in parallel;
         * when false all agents share one process-wide lock. Applies to agents created afterwards.
         */
        @JvmStatic
        @Volatile
        var parallelAgents: Boolean = System.getProperty("agentlean.parallel") != "false"

        private fun newLock(): Any = if (parallelAgents) Any() else GLOBAL_LOCK

        /** Recreate an agent from [snapshot] output. Feed [Events.resume] next to re-issue what was in flight. */
        @JvmStatic
        fun restore(snapshot: String): Agent = restore(snapshot.toByteArray(Charsets.UTF_8))

        @JvmStatic
        fun restore(snapshot: ByteArray): Agent = Agent(snapshot, true)
    }

    private fun h(): Long {
        if (handle == 0L) throw AgentException("agent is closed")
        return handle
    }

    private fun utf8(b: ByteArray): String = String(b, Charsets.UTF_8)

    /** Feed one event (UTF-8 JSON). */
    fun feed(event: String): FeedResult = synchronized(lock) { feed(event.toByteArray(Charsets.UTF_8)) }

    fun feed(event: ByteArray): FeedResult = synchronized(lock) {
        when (val code = AgentNative.feed(h(), event)) {
            0 -> FeedResult.Ok
            1 -> FeedResult.Invalid(lastError())
            2 -> FeedResult.Rejected(lastError())
            else -> FeedResult.Failed.also { check(code == -1) { "unknown agent_feed code $code" } }
        }
    }

    /** The next pending effect as JSON, or null when none is pending. */
    fun nextEffect(): String? = synchronized(lock) { nextEffectBytes()?.let(::utf8) }

    /** The next pending effect as the exact UTF-8 bytes the core produced, or null. */
    fun nextEffectBytes(): ByteArray? = synchronized(lock) { AgentNative.nextEffect(h()) }

    /** Pull every pending effect, in order. */
    fun effects(): List<String> = synchronized(lock) {
        val out = ArrayList<String>()
        while (true) out.add(nextEffect() ?: break)
        out
    }

    /** The state as a versioned snapshot (JSON); see [restore]. */
    fun snapshot(): String = synchronized(lock) { utf8(AgentNative.snapshot(h())) }

    /** The append-only trace of accepted events. May contain sensitive tool output: see [isSensitive]. */
    fun trace(): String = synchronized(lock) { utf8(AgentNative.trace(h())) }

    /** The trace with sensitive payloads hashed: safe to log or ship. */
    fun audit(): String = synchronized(lock) { utf8(AgentNative.audit(h())) }

    /** Message of the last invalid or rejected event. */
    fun lastError(): String = synchronized(lock) { utf8(AgentNative.lastError(h())) }

    /** Number of accepted events in the trace. */
    val traceLength: Long
        get() = synchronized(lock) { AgentNative.traceLen(h()) }

    /**
     * True once the run reached a terminal state (error, policy halt, cancel, limits). A `final`
     * answer leaves the run open for another user turn, so it is not done.
     */
    val isDone: Boolean
        get() = synchronized(lock) { AgentNative.isDone(h()) }

    /** True once output of a tool declared sensitive entered the run: encrypt the trace at rest. */
    val isSensitive: Boolean
        get() = synchronized(lock) { AgentNative.isSensitive(h()) }

    val isClosed: Boolean
        get() = synchronized(lock) { handle == 0L }

    /** Release the native handle. Idempotent; any later call throws [AgentException]. */
    override fun close() = synchronized(lock) {
        val h = handle
        handle = 0L
        if (h != 0L) AgentNative.free(h)
    }
}
