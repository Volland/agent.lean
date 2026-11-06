import AgentLeanC
import Foundation

/// One agent run over the agent.lean C ABI (`agent.h`).
///
/// The host drives it by feeding events and pulling effects; the core never calls back and never
/// starts threads. The C rule "one thread at a time per handle" is enforced here with a lock, so an
/// `Agent` may be shared across threads and tasks; distinct agents are independent.
public final class Agent: @unchecked Sendable {
  private let handle: OpaquePointer
  private let lock = NSLock()

  /// The C ABI version this binding was compiled against.
  public static let abiVersion = Int(AGENT_LEAN_ABI_VERSION)

  /// Create an agent from a run configuration, e.g.
  /// `{"agent":"assistant","model":"gpt-4.1-mini","endpoint":"https://api.openai.com/v1/chat/completions"}`.
  public init(config: Data) throws {
    handle = try Agent.create(config, agent_new)
  }

  /// Create an agent from a configuration dictionary (serialized with `JSONSerialization`).
  public convenience init(config: [String: Any]) throws {
    guard JSONSerialization.isValidJSONObject(config) else {
      throw AgentError.creationFailed("configuration is not a JSON object")
    }
    try self.init(config: try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]))
  }

  /// Create an agent from a configuration given as a JSON value.
  public convenience init(config: JSONValue) throws {
    try self.init(config: config.jsonData)
  }

  /// Recreate an agent from `snapshot()` output. Feed `.resume` next to re-issue what was in flight.
  public init(snapshot: Data) throws {
    handle = try Agent.create(snapshot, agent_restore)
  }

  deinit {
    agent_free(handle)
  }

  private static func create(
    _ bytes: Data,
    _ fn: (UnsafePointer<UInt8>?, Int, UnsafeMutablePointer<agent_buf_t>?) -> OpaquePointer?
  ) throws -> OpaquePointer {
    var err = agent_buf_t(data: nil, len: 0)
    let h = bytes.withUnsafeBytes { p in
      fn(p.bindMemory(to: UInt8.self).baseAddress, p.count, &err)
    }
    let message = Agent.take(err)
    guard let h else {
      throw AgentError.creationFailed(message.isEmpty ? "unknown error" : String(decoding: message, as: UTF8.self))
    }
    return h
  }

  /// Copy a caller-owned buffer into `Data` and release it.
  private static func take(_ b: agent_buf_t) -> Data {
    defer { agent_buf_free(b) }
    guard let p = b.data, b.len > 0 else { return Data() }
    return Data(bytes: p, count: b.len)
  }

  @inline(__always)
  private func locked<T>(_ body: (OpaquePointer) throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body(handle)
  }

  // MARK: Driving

  /// Feed one event as UTF-8 JSON bytes. `invalid` and `rejected` leave the state unchanged and
  /// carry the core's message; a failed call (`AGENT_FAILED`) throws.
  @discardableResult
  public func feed(_ event: Data) throws -> FeedResult {
    try locked { h in
      let code = event.withUnsafeBytes { p in
        agent_feed(h, p.bindMemory(to: UInt8.self).baseAddress, p.count)
      }
      switch Int(code) {
      case Int(AGENT_OK): return .ok
      case Int(AGENT_INVALID): return .invalid(lastErrorUnlocked(h))
      case Int(AGENT_REJECTED): return .rejected(lastErrorUnlocked(h))
      default: throw AgentError.callFailed("agent_feed returned \(code)")
      }
    }
  }

  /// Feed one typed event.
  @discardableResult
  public func feed(_ event: Event) throws -> FeedResult {
    try feed(event.jsonData)
  }

  /// Pull the next pending effect as UTF-8 JSON bytes, or `nil` if none is pending.
  public func nextEffect() -> Data? {
    locked { h in
      var b = agent_buf_t(data: nil, len: 0)
      guard agent_next_effect(h, &b) == 1 else { return nil }
      return Agent.take(b)
    }
  }

  /// Pull every pending effect, in order, as UTF-8 JSON bytes.
  public func effects() -> [Data] {
    locked { h in
      var out: [Data] = []
      var b = agent_buf_t(data: nil, len: 0)
      while agent_next_effect(h, &b) == 1 {
        out.append(Agent.take(b))
        b = agent_buf_t(data: nil, len: 0)
      }
      return out
    }
  }

  /// Pull the next pending effect, decoded.
  public func nextTypedEffect() throws -> Effect? {
    try nextEffect().map(Effect.init(json:))
  }

  /// Pull every pending effect, decoded.
  public func typedEffects() throws -> [Effect] {
    try effects().map(Effect.init(json:))
  }

  // MARK: State

  /// The state as a versioned snapshot (JSON); restore it with `Agent(snapshot:)`.
  public func snapshot() -> Data { locked { Agent.take(agent_snapshot($0)) } }

  /// The append-only trace of accepted events (JSON).
  public func trace() -> Data { locked { Agent.take(agent_trace($0)) } }

  /// The audit form of the trace: sensitive payloads replaced by hashes (JSON).
  public func audit() -> Data { locked { Agent.take(agent_audit($0)) } }

  /// Number of accepted events in the trace.
  public var traceLength: UInt64 { locked { agent_trace_len($0) } }

  /// Message of the last `invalid` / `rejected` feed.
  public var lastError: String { locked { lastErrorUnlocked($0) } }

  /// Whether the run is over.
  public var isDone: Bool { locked { agent_is_done($0) != 0 } }

  /// True once output of a tool declared sensitive entered the run: encrypt the trace at rest.
  public var isSensitive: Bool { locked { agent_is_sensitive($0) != 0 } }

  private func lastErrorUnlocked(_ h: OpaquePointer) -> String {
    String(decoding: Agent.take(agent_last_error(h)), as: UTF8.self)
  }
}
