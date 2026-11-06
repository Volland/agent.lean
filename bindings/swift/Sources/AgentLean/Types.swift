import Foundation

// MARK: - Errors and feed results

/// Errors raised by the binding. Invalid or rejected events are *results* of `feed`, not errors.
public enum AgentError: Error, Sendable, CustomStringConvertible {
  /// `agent_new` / `agent_restore` failed; the message comes from the core.
  case creationFailed(String)
  /// A C call failed (`AGENT_FAILED`: out of memory or a bad handle).
  case callFailed(String)
  /// An effect could not be decoded into the typed `Effect` model.
  case undecodableEffect(String)
  /// JSON given to `Event(json:)` is not a known event.
  case malformedEvent(String)
  /// The driver fed an event the core did not accept.
  case eventNotAccepted(FeedResult)
  /// The driver has nothing in flight but the run has not completed.
  case stalled
  /// The run completed with a reason other than `final` (error, policy halt, budget, cancel...).
  case runEnded(Completion)

  public var description: String {
    switch self {
    case .creationFailed(let m): return "agent creation failed: \(m)"
    case .callFailed(let m): return "agent call failed: \(m)"
    case .undecodableEffect(let m): return "undecodable effect: \(m)"
    case .malformedEvent(let m): return "malformed event: \(m)"
    case .eventNotAccepted(let r): return "event not accepted: \(r)"
    case .stalled: return "the run stalled: nothing in flight and no completion"
    case .runEnded(let c): return "the run ended with reason '\(c.reason)'" + (c.detail.map { ": \($0)" } ?? "")
    }
  }
}

/// Outcome of `Agent.feed`. `invalid` and `rejected` leave the agent's state unchanged.
public enum FeedResult: Sendable, Equatable, CustomStringConvertible {
  case ok
  /// Not valid JSON or not a known event (`AGENT_INVALID`), with the core's message.
  case invalid(String)
  /// Not expected in the current state (`AGENT_REJECTED`), with the core's message.
  case rejected(String)

  public var isOK: Bool { self == .ok }

  public var description: String {
    switch self {
    case .ok: return "ok"
    case .invalid(let m): return "invalid: \(m)"
    case .rejected(let m): return "rejected: \(m)"
    }
  }
}

// MARK: - Events (host -> core)

/// An event the host feeds to the agent. `Agent.feed(_:)` also accepts raw JSON bytes.
public enum Event: Sendable, Equatable {
  /// A user turn.
  case user(text: String)
  /// A complete (non-streamed) model response for request `id`.
  case llmResponse(id: String, status: Int, body: String)
  /// A chunk of a streamed model response for request `id`, as raw bytes (any split is fine).
  case llmChunk(id: String, data: Data)
  /// The stream for request `id` ended.
  case llmEnd(id: String)
  /// Request `id` failed in transport.
  case llmError(id: String, message: String)
  /// The result of tool call `id`.
  case toolResult(id: String, result: JSONValue)
  /// Tool call `id` failed in the host.
  case toolError(id: String, message: String)
  /// The host cancels the run.
  case cancel
  /// After `Agent(snapshot:)`: re-issue what was in flight.
  case resume

  /// The event as a JSON value, in the core's wire format.
  public var json: JSONValue {
    switch self {
    case .user(let t): return ["type": "user", "text": .string(t)]
    case .llmResponse(let i, let s, let b):
      return ["type": "llm_response", "id": .string(i), "status": .int(Int64(s)), "body": .string(b)]
    case .llmChunk(let i, let d): return ["type": "llm_chunk", "id": .string(i), "b64": .string(d.base64EncodedString())]
    case .llmEnd(let i): return ["type": "llm_end", "id": .string(i)]
    case .llmError(let i, let m): return ["type": "llm_error", "id": .string(i), "message": .string(m)]
    case .toolResult(let i, let r): return ["type": "tool_result", "id": .string(i), "result": r]
    case .toolError(let i, let m): return ["type": "tool_error", "id": .string(i), "message": .string(m)]
    case .cancel: return ["type": "cancel"]
    case .resume: return ["type": "resume"]
    }
  }

  /// UTF-8 JSON bytes, as fed through `agent_feed`.
  public var jsonData: Data { json.jsonData }

  /// Parse an event from its JSON form (the inverse of `jsonData`).
  public init(json data: Data) throws {
    let v = try JSONValue(json: data)
    func str(_ k: String) throws -> String {
      guard let s = v[k]?.stringValue else { throw AgentError.malformedEvent("event field '\(k)' missing") }
      return s
    }
    switch try str("type") {
    case "user": self = .user(text: try str("text"))
    case "llm_response":
      self = .llmResponse(id: try str("id"), status: Int(v["status"]?.intValue ?? 200), body: try str("body"))
    case "llm_chunk":
      if let b = v["b64"]?.stringValue {
        guard let d = Data(base64Encoded: b) else { throw AgentError.malformedEvent("bad base64 in llm_chunk") }
        self = .llmChunk(id: try str("id"), data: d)
      } else {
        self = .llmChunk(id: try str("id"), data: Data(try str("data").utf8))
      }
    case "llm_end": self = .llmEnd(id: try str("id"))
    case "llm_error": self = .llmError(id: try str("id"), message: try str("message"))
    case "tool_result": self = .toolResult(id: try str("id"), result: v["result"] ?? .null)
    case "tool_error": self = .toolError(id: try str("id"), message: try str("message"))
    case "cancel": self = .cancel
    case "resume": self = .resume
    case let t: throw AgentError.malformedEvent("unknown event type '\(t)'")
    }
  }

  /// Every event but a stream chunk ends the operation it answers.
  var isTerminal: Bool {
    if case .llmChunk = self { return false }
    return true
  }
}

// MARK: - Effects (core -> host)

/// A model request: POST `body` to `url` with `headers`. The host injects the secret named by
/// `credential` using the `auth` scheme; the core never sees it.
public struct LLMRequest: Sendable, Equatable, Codable {
  public var id: String
  public var url: String
  /// Name of the credential the host must inject (e.g. `openai`), never the secret itself.
  public var credential: String
  /// How to inject it: `bearer` (`Authorization: Bearer ...`) or `x-api-key`.
  public var auth: String
  public var headers: [String: String]
  public var body: String
  /// Whether the body asks for a streamed (SSE) response; feed chunks then `llmEnd` if so.
  public var stream: Bool

  /// A `URLRequest` for this effect, with `secret` (the value of `credential`, looked up by the
  /// host, e.g. from the Keychain) placed in the header the `auth` scheme names.
  public func urlRequest(secret: String?) throws -> URLRequest {
    guard let u = URL(string: url) else { throw AgentError.callFailed("bad request url '\(url)'") }
    var r = URLRequest(url: u)
    r.httpMethod = "POST"
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    if let secret {
      switch auth.lowercased() {
      case "bearer": r.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
      default: r.setValue(secret, forHTTPHeaderField: auth)
      }
    }
    r.httpBody = Data(body.utf8)
    return r
  }
}

/// A tool call the host must perform; answer with `Event.toolResult` or `Event.toolError`.
public struct ToolCall: Sendable, Equatable, Codable {
  public var id: String
  public var name: String
  public var args: JSONValue
  /// `host` (the application implements it), `io`, `pure` or `agent`.
  public var executor: String
  /// The application-level id of a host tool (e.g. `net.fetch`), when `executor == "host"`.
  public var hostID: String?
  /// The sub-agent's name, when `executor == "agent"`.
  public var agent: String?

  enum CodingKeys: String, CodingKey {
    case id, name, args, executor, agent
    case hostID = "host_id"
  }
}

/// A display-only event.
public enum DisplayEvent: Sendable, Equatable {
  case textDelta(String)
  case toolStart(id: String, name: String)
  case toolEnd(id: String, name: String, ok: Bool)
  case other(kind: String)
}

/// The run is over.
public struct Completion: Sendable, Equatable, Codable {
  /// `final` for a normal answer; otherwise e.g. `error`, `policy_halt`, `cancelled`, a budget reason.
  public var reason: String
  public var answer: String
  public var detail: String?
}

/// A typed effect. `raw` cases of `Agent.nextEffect()` are the byte-exact source of these.
public enum Effect: Sendable, Equatable {
  case llmRequest(LLMRequest)
  case toolCall(ToolCall)
  case ui(DisplayEvent)
  case complete(Completion)
  /// A kind this binding does not know yet; the raw JSON is kept.
  case unknown(type: String, raw: Data)

  /// Decode an effect from the JSON bytes `agent_next_effect` returned.
  public init(json data: Data) throws {
    let d = JSONDecoder()
    let v: JSONValue
    do { v = try JSONValue(json: data) } catch {
      throw AgentError.undecodableEffect(String(decoding: data, as: UTF8.self))
    }
    let type = v["type"]?.stringValue ?? ""
    do {
      switch type {
      case "llm_request": self = .llmRequest(try d.decode(LLMRequest.self, from: data))
      case "tool_call": self = .toolCall(try d.decode(ToolCall.self, from: data))
      case "complete": self = .complete(try d.decode(Completion.self, from: data))
      case "ui":
        let kind = v["kind"]?.stringValue ?? ""
        let id = v["id"]?.stringValue ?? ""
        let name = v["name"]?.stringValue ?? ""
        switch kind {
        case "text_delta": self = .ui(.textDelta(v["text"]?.stringValue ?? ""))
        case "tool_start": self = .ui(.toolStart(id: id, name: name))
        case "tool_end": self = .ui(.toolEnd(id: id, name: name, ok: v["ok"]?.boolValue ?? false))
        default: self = .ui(.other(kind: kind))
        }
      default: self = .unknown(type: type, raw: data)
      }
    } catch {
      throw AgentError.undecodableEffect("\(error): \(String(decoding: data, as: UTF8.self))")
    }
  }
}
