package dev.agentlean

import java.io.File

/**
 * Loads the JNI library `agentlean_jni` once per process.
 *
 * On Android and on a desktop JVM with `-Djava.library.path=...` this is
 * `System.loadLibrary("agentlean_jni")`. Setting the system property [PATH_PROPERTY]
 * (`-Dagentlean.jni.path=/abs/path/libagentlean_jni.dylib`) loads that exact file instead,
 * which is what the desktop tests do. Call [load] early to fail fast; [Agent] calls it lazily.
 */
object NativeLoader {
    const val LIBRARY = "agentlean_jni"
    const val PATH_PROPERTY = "agentlean.jni.path"

    @Volatile private var loaded = false

    @JvmStatic
    @Synchronized
    fun load() {
        if (loaded) return
        val path = System.getProperty(PATH_PROPERTY)
        if (!path.isNullOrEmpty()) System.load(File(path).absolutePath) else System.loadLibrary(LIBRARY)
        loaded = true
    }
}

/** The raw JNI surface (jni/agent_jni.c). Payloads are UTF-8 byte arrays; handles are pointers. */
internal object AgentNative {
    init {
        NativeLoader.load()
        val v = abiVersion()
        check(v == Agent.ABI_VERSION) { "agentlean_jni has ABI version $v, binding expects ${Agent.ABI_VERSION}" }
    }

    @JvmStatic external fun abiVersion(): Int
    @JvmStatic external fun create(config: ByteArray): Long
    @JvmStatic external fun restore(snapshot: ByteArray): Long
    @JvmStatic external fun feed(handle: Long, event: ByteArray): Int
    @JvmStatic external fun nextEffect(handle: Long): ByteArray?
    @JvmStatic external fun snapshot(handle: Long): ByteArray
    @JvmStatic external fun trace(handle: Long): ByteArray
    @JvmStatic external fun audit(handle: Long): ByteArray
    @JvmStatic external fun lastError(handle: Long): ByteArray
    @JvmStatic external fun traceLen(handle: Long): Long
    @JvmStatic external fun isDone(handle: Long): Boolean
    @JvmStatic external fun isSensitive(handle: Long): Boolean
    @JvmStatic external fun free(handle: Long)
}
