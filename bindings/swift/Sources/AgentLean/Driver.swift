import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// What a transport returns for a model request.
public struct LLMResponse: Sendable {
  public enum Body: Sendable {
    /// The whole body at once.
    case data(Data)
    /// The body as it arrives (SSE bytes for streamed requests); any split is fine.
    case stream(AsyncThrowingStream<Data, Error>)
  }

  public var status: Int
  public var body: Body

  public init(status: Int, body: Body) {
    self.status = status
    self.body = body
  }

  public static func complete(status: Int = 200, body: Data) -> LLMResponse {
    LLMResponse(status: status, body: .data(body))
  }

  public static func complete(status: Int = 200, body: String) -> LLMResponse {
    LLMResponse(status: status, body: .data(Data(body.utf8)))
  }

  public static func stream(status: Int = 200, _ chunks: AsyncThrowingStream<Data, Error>) -> LLMResponse {
    LLMResponse(status: status, body: .stream(chunks))
  }
}

/// Performs a model request: POST `request.body` to `request.url` with `request.headers`, plus the
/// secret named by `request.credential`, injected by the host (see `LLMRequest.urlRequest(secret:)`).
public typealias LLMTransport = @Sendable (LLMRequest) async throws -> LLMResponse

/// Performs a host tool and returns its JSON result; a thrown error becomes a `tool_error` event.
public typealias ToolHandler = @Sendable (ToolCall) async throws -> JSONValue

extension Agent {
  /// Run one user turn to completion and return the final answer.
  ///
  /// Model requests go through `transport`, tool calls to `tools` (looked up by the call's
  /// `hostID`, then by its `name`; a missing handler is reported to the agent as a tool error).
  /// Requests and tool calls that the agent issues together run concurrently; their results are
  /// fed back one at a time. Cancelling the calling task feeds `cancel` and throws
  /// `CancellationError`. A run that ends with a reason other than `final` throws
  /// `AgentError.runEnded`.
  public func run(
    user text: String,
    transport: @escaping LLMTransport,
    tools: [String: ToolHandler] = [:],
    onUI: (@Sendable (DisplayEvent) -> Void)? = nil
  ) async throws -> String {
    let c = try await drive(.user(text: text), transport: transport, tools: tools, onUI: onUI)
    guard c.reason == "final" else { throw AgentError.runEnded(c) }
    return c.answer
  }

  /// Feed `first` and keep performing effects until the agent emits `complete`; return it.
  /// Use `.resume` as `first` to continue a run restored from a snapshot.
  public func drive(
    _ first: Event,
    transport: @escaping LLMTransport,
    tools: [String: ToolHandler] = [:],
    onUI: (@Sendable (DisplayEvent) -> Void)? = nil
  ) async throws -> Completion {
    let (events, sink) = AsyncStream<Event>.makeStream()
    return try await withThrowingTaskGroup(of: Void.self) { group in
      defer {
        sink.finish()
        group.cancelAll()
      }
      var inFlight = 0
      var completion: Completion?

      // Feed one event and start whatever it asks for.
      func step(_ e: Event) throws {
        let r = try feed(e)
        guard r.isOK else { throw AgentError.eventNotAccepted(r) }
        for effect in try typedEffects() {
          switch effect {
          case .llmRequest(let req):
            inFlight += 1
            group.addTask { await Agent.perform(req, transport, sink) }
          case .toolCall(let call):
            inFlight += 1
            let handler = call.hostID.flatMap { tools[$0] } ?? tools[call.name]
            group.addTask { await Agent.perform(call, handler, sink) }
          case .ui(let u):
            onUI?(u)
          case .complete(let c):
            completion = c
          case .unknown:
            break
          }
        }
      }

      try step(first)
      var it = events.makeAsyncIterator()
      while completion == nil {
        if inFlight == 0 { throw AgentError.stalled }
        let next = await it.next()
        if Task.isCancelled {
          _ = try? feed(.cancel)
          for case .ui(let u) in (try? typedEffects()) ?? [] { onUI?(u) }
          throw CancellationError()
        }
        guard let e = next else { throw AgentError.stalled }
        if e.isTerminal { inFlight -= 1 }
        try step(e)
      }
      return completion!
    }
  }

  private static func perform(
    _ req: LLMRequest, _ transport: LLMTransport, _ sink: AsyncStream<Event>.Continuation
  ) async {
    do {
      let resp = try await transport(req)
      switch resp.body {
      case .data(let d):
        sink.yield(.llmResponse(id: req.id, status: resp.status, body: String(decoding: d, as: UTF8.self)))
      case .stream(let chunks):
        if resp.status >= 400 {
          // An error status is reported with its body, as a complete response.
          var all = Data()
          for try await c in chunks { all.append(c) }
          sink.yield(.llmResponse(id: req.id, status: resp.status, body: String(decoding: all, as: UTF8.self)))
        } else {
          for try await c in chunks where !c.isEmpty { sink.yield(.llmChunk(id: req.id, data: c)) }
          sink.yield(.llmEnd(id: req.id))
        }
      }
    } catch {
      sink.yield(.llmError(id: req.id, message: "\(error)"))
    }
  }

  private static func perform(
    _ call: ToolCall, _ handler: ToolHandler?, _ sink: AsyncStream<Event>.Continuation
  ) async {
    guard let handler else {
      sink.yield(.toolError(id: call.id, message: "no handler for tool '\(call.name)'"))
      return
    }
    do {
      sink.yield(.toolResult(id: call.id, result: try await handler(call)))
    } catch {
      sink.yield(.toolError(id: call.id, message: "\(error)"))
    }
  }
}

#if canImport(Darwin)
  extension Agent {
    /// A transport over `URLSession`. `secret` maps a credential name (e.g. `openai`) to its value,
    /// e.g. from the Keychain; the value goes straight into the request header and is not kept.
    /// Streamed requests are delivered line by line as they arrive.
    public static func urlSessionTransport(
      _ session: URLSession = .shared,
      secret: @escaping @Sendable (String) async throws -> String?
    ) -> LLMTransport {
      return { req in
        let r = try req.urlRequest(secret: try await secret(req.credential))
        if !req.stream {
          let (data, resp) = try await session.data(for: r)
          return .complete(status: (resp as? HTTPURLResponse)?.statusCode ?? 200, body: data)
        }
        let (bytes, resp) = try await session.bytes(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
        let chunks = AsyncThrowingStream<Data, Error> { cont in
          let task = Task {
            do {
              var line = Data()
              for try await b in bytes {
                line.append(b)
                if b == UInt8(ascii: "\n") || line.count >= 16 * 1024 {
                  cont.yield(line)
                  line = Data()
                }
              }
              if !line.isEmpty { cont.yield(line) }
              cont.finish()
            } catch {
              cont.finish(throwing: error)
            }
          }
          cont.onTermination = { _ in task.cancel() }
        }
        return .stream(status: status, chunks)
      }
    }
  }
#endif
