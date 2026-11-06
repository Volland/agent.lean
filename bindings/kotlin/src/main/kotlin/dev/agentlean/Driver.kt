package dev.agentlean

/** What the host's HTTP transport got for an [Effect.LlmRequest]. */
sealed class LlmReply {
    /** A complete response body. */
    data class Response(val status: Int, val body: String) : LlmReply()

    /** A streamed response (`stream: true`), as raw byte chunks in arrival order. */
    class Stream(val chunks: Iterable<ByteArray>) : LlmReply()
}

/**
 * Performs model requests. Look up the secret named by [Effect.LlmRequest.credential] in the host's
 * own store and add it with [Effect.LlmRequest.authHeader]. Throwing reports a transport failure
 * (`llm_error`) to the agent.
 */
fun interface Transport {
    fun send(request: Effect.LlmRequest): LlmReply
}

/** Runs host tools. Return the result as a JSON value (see [Json.write]); throwing reports `tool_error`. */
fun interface ToolExecutor {
    fun call(call: Effect.ToolCall): String
}

/**
 * Drive the agent to completion for one user turn, blocking the calling thread, and return the
 * final [Effect.Complete]. Effects are performed one at a time in the order the core emits them;
 * [onUi] receives display-only effects (streamed text deltas as soon as each chunk is fed).
 *
 * From a coroutine: `withContext(Dispatchers.IO) { agent.run(text, transport, tools) }`.
 */
fun Agent.run(
    user: String,
    transport: Transport,
    tools: ToolExecutor = ToolExecutor { throw UnsupportedOperationException("no host tool executor for '${it.name}'") },
    onUi: (Effect.Ui) -> Unit = {},
): Effect.Complete {
    val pending = ArrayDeque<Effect>()

    fun feedOrThrow(event: String) {
        when (val r = feed(event)) {
            FeedResult.Ok -> {}
            is FeedResult.Invalid -> throw AgentException("event invalid: ${r.message}")
            is FeedResult.Rejected -> throw AgentException("event rejected: ${r.message}")
            FeedResult.Failed -> throw AgentException("agent_feed failed")
        }
    }

    fun pull(uiNow: Boolean) {
        while (true) {
            val e = Effect.parse(nextEffect() ?: return)
            if (uiNow && e is Effect.Ui) onUi(e) else pending.addLast(e)
        }
    }

    feedOrThrow(Events.user(user))
    while (true) {
        if (pending.isEmpty()) pull(uiNow = false)
        val e = pending.removeFirstOrNull()
            ?: throw AgentException("run stalled: no pending effects and no completion")
        when (e) {
            is Effect.Complete -> return e
            is Effect.Ui -> onUi(e)
            is Effect.Unknown -> {}
            is Effect.LlmRequest -> {
                val reply = try {
                    transport.send(e)
                } catch (x: Exception) {
                    feedOrThrow(Events.llmError(e.id, x.message ?: x.toString()))
                    continue
                }
                when (reply) {
                    is LlmReply.Response -> feedOrThrow(Events.llmResponse(e.id, reply.status, reply.body))
                    is LlmReply.Stream -> {
                        try {
                            for (chunk in reply.chunks) {
                                feedOrThrow(Events.llmChunk(e.id, chunk))
                                pull(uiNow = true)
                            }
                        } catch (x: AgentException) {
                            throw x
                        } catch (x: Exception) {
                            feedOrThrow(Events.llmError(e.id, x.message ?: x.toString()))
                            continue
                        }
                        feedOrThrow(Events.llmEnd(e.id))
                    }
                }
            }
            is Effect.ToolCall -> {
                val result = try {
                    tools.call(e)
                } catch (x: Exception) {
                    feedOrThrow(Events.toolError(e.id, x.message ?: x.toString()))
                    continue
                }
                feedOrThrow(Events.toolResult(e.id, result))
            }
        }
    }
}
