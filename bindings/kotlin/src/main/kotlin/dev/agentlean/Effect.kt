package dev.agentlean

/**
 * A typed view of one effect (core -> host). Every variant keeps the exact JSON it was read from
 * in [json]; the binding never re-serializes what the core produced.
 */
sealed class Effect {
    abstract val json: String

    /**
     * POST [body] to [url] with [headers]. [credential] only *names* the secret (for example
     * `openai`): the host looks the secret up in its own store and sends it in the header that
     * [auth] names. The core never sees a credential value.
     */
    data class LlmRequest(
        val id: String,
        val url: String,
        val credential: String,
        val auth: String,
        val headers: Map<String, String>,
        val body: String,
        val stream: Boolean,
        override val json: String,
    ) : Effect() {
        /** The header carrying [secret] for this request's [auth] scheme (`bearer` or `x-api-key`). */
        fun authHeader(secret: String): Pair<String, String> = when (auth) {
            "x-api-key" -> "x-api-key" to secret
            else -> "authorization" to "Bearer $secret"
        }
    }

    /** Run tool [name] with [argsJson] (the exact JSON of the arguments) in the host. */
    data class ToolCall(
        val id: String,
        val name: String,
        val argsJson: String,
        val executor: String,
        val hostId: String?,
        val agent: String?,
        override val json: String,
    ) : Effect() {
        /** The arguments parsed with [Json.parse]. */
        val args: Any? get() = Json.parse(argsJson)
    }

    /** Display-only: [kind] is `text_delta` (with [text]), `tool_start` or `tool_end` (with [ok]). */
    data class Ui(
        val kind: String,
        val text: String?,
        val id: String?,
        val name: String?,
        val ok: Boolean?,
        override val json: String,
    ) : Effect()

    /** The run is over; [reason] is e.g. `final`, `error`, `policy_halt`. */
    data class Complete(
        val reason: String,
        val answer: String,
        val detail: String?,
        override val json: String,
    ) : Effect()

    /** An effect type this binding version does not know; handle it from [json] or ignore it. */
    data class Unknown(val type: String?, override val json: String) : Effect()

    companion object {
        @JvmStatic
        fun parse(json: String): Effect {
            val raw = Json.members(json)
            fun str(k: String): String? = raw[k]?.let { Json.parse(it) as? String }
            fun req(k: String): String = str(k) ?: throw Json.ParseException("effect without string '$k': $json")
            return when (val type = str("type")) {
                "llm_request" -> {
                    @Suppress("UNCHECKED_CAST")
                    val headers = (raw["headers"]?.let { Json.parse(it) } as? Map<String, Any?>)
                        ?.mapValues { it.value.toString() } ?: emptyMap()
                    LlmRequest(
                        req("id"), req("url"), req("credential"), str("auth") ?: "bearer", headers,
                        req("body"), raw["stream"] == "true", json,
                    )
                }
                "tool_call" -> ToolCall(
                    req("id"), req("name"), raw["args"] ?: "null", str("executor") ?: "host",
                    str("host_id"), str("agent"), json,
                )
                "ui" -> Ui(req("kind"), str("text"), str("id"), str("name"), raw["ok"]?.let { it == "true" }, json)
                "complete" -> Complete(req("reason"), str("answer") ?: "", str("detail"), json)
                else -> Unknown(type, json)
            }
        }
    }
}

/** Builders for event JSON (host -> core). */
object Events {
    @JvmStatic fun user(text: String): String = """{"type":"user","text":${Json.quote(text)}}"""

    @JvmStatic fun llmResponse(id: String, status: Int, body: String): String =
        """{"type":"llm_response","id":${Json.quote(id)},"status":$status,"body":${Json.quote(body)}}"""

    /** One chunk of a streamed response, as raw bytes (any split, even inside a UTF-8 character). */
    @JvmStatic fun llmChunk(id: String, data: ByteArray): String =
        """{"type":"llm_chunk","id":${Json.quote(id)},"b64":"${Base64Codec.encode(data)}"}"""

    @JvmStatic fun llmEnd(id: String): String = """{"type":"llm_end","id":${Json.quote(id)}}"""

    @JvmStatic fun llmError(id: String, message: String): String =
        """{"type":"llm_error","id":${Json.quote(id)},"message":${Json.quote(message)}}"""

    /** [resultJson] must be a JSON value, e.g. `{"ok":true}` or `"text"` (see [Json.write]). */
    @JvmStatic fun toolResult(id: String, resultJson: String): String =
        """{"type":"tool_result","id":${Json.quote(id)},"result":$resultJson}"""

    @JvmStatic fun toolError(id: String, message: String): String =
        """{"type":"tool_error","id":${Json.quote(id)},"message":${Json.quote(message)}}"""

    @JvmStatic fun cancel(): String = """{"type":"cancel"}"""

    /** Feed after [Agent.restore] to re-issue what was in flight. */
    @JvmStatic fun resume(): String = """{"type":"resume"}"""
}
