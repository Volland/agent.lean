import Foundation
import XCTest

@testable import AgentLean

/// Repository root, located from this file: bindings/swift/Tests/AgentLeanTests/<file>.
private let repoRoot: URL = {
  var u = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { u.deleteLastPathComponent() }
  return u
}()

/// A golden trace: the config, then each event with the effects it must produce, byte for byte.
private struct Golden {
  var name: String
  var config: Data
  var steps: [(event: Data, effects: [Data])]
}

private func loadGoldens() throws -> [Golden] {
  let dir = repoRoot.appendingPathComponent("traces")
  let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
    .filter { $0.hasSuffix(".golden") }.sorted()
  return try files.map { f in
    let bytes = try Data(contentsOf: dir.appendingPathComponent(f))
    let lines = bytes.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).map { Data($0) }
    func tagged(_ l: Data, _ t: String) -> Data? {
      l.starts(with: Data((t + " ").utf8)) ? l.dropFirst(2) : nil
    }
    guard let first = lines.first, let config = tagged(first, "C") else {
      throw XCTSkip("\(f): no config line")
    }
    var g = Golden(name: f, config: Data(config), steps: [])
    for l in lines.dropFirst() {
      if let e = tagged(l, "E") {
        g.steps.append((Data(e), []))
      } else if let x = tagged(l, "X"), !g.steps.isEmpty {
        g.steps[g.steps.count - 1].effects.append(Data(x))
      } else {
        XCTFail("\(f): unexpected line \(String(decoding: l, as: UTF8.self))")
      }
    }
    return g
  }
}

/// Replay one golden through the Swift API; returns the first difference, or nil.
private func replay(_ g: Golden, reencode: Bool = false) throws -> String? {
  let agent = try Agent(config: g.config)
  for (i, step) in g.steps.enumerated() {
    let event = reencode ? try Event(json: step.event).jsonData : step.event
    let r = try agent.feed(event)
    if r != .ok { return "\(g.name) event \(i + 1): \(r)" }
    let got = agent.effects()
    for (j, want) in step.effects.enumerated() {
      guard j < got.count else {
        return "\(g.name) event \(i + 1): missing effect \(String(decoding: want, as: UTF8.self))"
      }
      if got[j] != want {
        return "\(g.name) event \(i + 1) effect \(j + 1) differs\n  want \(String(decoding: want, as: UTF8.self))\n  got  \(String(decoding: got[j], as: UTF8.self))"
      }
    }
    if got.count > step.effects.count {
      return "\(g.name) event \(i + 1): unexpected extra effect \(String(decoding: got[step.effects.count], as: UTF8.self))"
    }
  }
  return nil
}

/// Run `body` on a fresh thread (which exits afterwards) and wait for it.
private func onNewThread<T>(_ body: @escaping () throws -> T) throws -> T {
  var result: Result<T, Error>?
  let done = DispatchSemaphore(value: 0)
  let t = Thread {
    result = Result { try body() }
    done.signal()
  }
  t.start()
  done.wait()
  return try result!.get()
}

/// Thread-safe recorder for the fake transport and tools.
private final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [LLMRequest] = []
  private var _tools: [ToolCall] = []
  private var _ui: [DisplayEvent] = []
  func request(_ r: LLMRequest) -> Int { lock.withLock { _requests.append(r); return _requests.count } }
  func tool(_ c: ToolCall) { lock.withLock { _tools.append(c) } }
  func ui(_ u: DisplayEvent) { lock.withLock { _ui.append(u) } }
  var requests: [LLMRequest] { lock.withLock { _requests } }
  var tools: [ToolCall] { lock.withLock { _tools } }
  var uiEvents: [DisplayEvent] { lock.withLock { _ui } }
}

private let localConfig: JSONValue = [
  "agent": "assistant", "model": "test-model", "endpoint": "http://localhost:8080/v1/chat/completions",
]

/// An OpenAI chat-completions reply with plain text.
private func textReply(_ text: String) -> String {
  JSONValue.object([
    "choices": [["message": ["role": "assistant", "content": .string(text)], "finish_reason": "stop"]],
    "usage": ["total_tokens": 10],
  ]).jsonString
}

/// An OpenAI chat-completions reply with one tool call.
private func toolReply(id: String, name: String, args: JSONValue) -> String {
  JSONValue.object([
    "choices": [[
      "message": [
        "role": "assistant", "content": nil,
        "tool_calls": [["id": .string(id), "type": "function",
                        "function": ["name": .string(name), "arguments": .string(args.jsonString)]]],
      ],
      "finish_reason": "tool_calls",
    ]],
    "usage": ["total_tokens": 10],
  ]).jsonString
}

final class AgentLeanTests: XCTestCase {
  // @tg: verifies:: [[openspec:host-abi#Native bindings#Golden trace through bindings]] {level: e2e}
  func testGoldenTracesThroughSwiftBinding() throws {
    let goldens = try loadGoldens()
    XCTAssertGreaterThanOrEqual(goldens.count, 8, "expected the golden traces in \(repoRoot.path)/traces")
    var effects = 0
    for g in goldens {
      if let diff = try replay(g) { XCTFail(diff) }
      effects += g.steps.reduce(0) { $0 + $1.effects.count }
    }
    XCTAssertGreaterThan(effects, 0)
  }

  /// The typed `Event` codec feeds the same events: re-encoding every golden event changes nothing,
  /// and every golden effect decodes into a known `Effect` case.
  func testGoldenTracesThroughTypedCodec() throws {
    for g in try loadGoldens() {
      if let diff = try replay(g, reencode: true) { XCTFail("re-encoded: " + diff) }
      for step in g.steps {
        for x in step.effects {
          if case .unknown(let t, _) = try Effect(json: x) { XCTFail("\(g.name): unknown effect type \(t)") }
        }
      }
    }
  }

  /// One agent used from many threads, one at a time (the C contract), stays byte-identical. Each
  /// event is fed on a new thread that exits afterwards.
  func testOneAgentAcrossThreads() throws {
    for g in try loadGoldens() {
      let agent = try Agent(config: g.config)
      for step in g.steps {
        let got = try onNewThread { () throws -> [Data] in
          guard try agent.feed(step.event) == .ok else { throw AgentError.callFailed(agent.lastError) }
          return agent.effects()
        }
        XCTAssertEqual(got, step.effects, g.name)
      }
    }
  }

  /// Distinct agents driven concurrently from many threads (each handle by one thread at a time).
  /// Guards ADR 0017: the registered agents are persistent, so concurrent handles share nothing mutable.
  // @tg: verifies:: [[openspec:host-abi#Handle thread confinement#Two agents on two threads]] {level: integration}
  func testConcurrentAgentsOnManyThreads() throws {
    let goldens = try loadGoldens()
    let lock = NSLock()
    var failures: [String] = []
    DispatchQueue.concurrentPerform(iterations: goldens.count * 4) { i in
      let result: String?
      do { result = try replay(goldens[i % goldens.count]) } catch { result = "\(error)" }
      if let result { lock.withLock { failures.append(result) } }
    }
    XCTAssertEqual(failures, [])
  }

  func testCreationFailureThrows() {
    XCTAssertThrowsError(try Agent(config: Data("{\"agent\":\"no-such-agent\"}".utf8))) { e in
      guard case AgentError.creationFailed(let m) = e else { return XCTFail("\(e)") }
      XCTAssertFalse(m.isEmpty)
    }
  }

  func testInvalidAndRejectedEventsLeaveStateUnchanged() throws {
    let agent = try Agent(config: localConfig)
    let before = agent.snapshot()
    guard case .invalid(let m) = try agent.feed(Data("not json".utf8)) else { return XCTFail("expected invalid") }
    XCTAssertFalse(m.isEmpty)
    XCTAssertEqual(agent.snapshot(), before)
    XCTAssertEqual(agent.traceLength, 0)
    XCTAssertNil(agent.nextEffect())

    XCTAssertEqual(try agent.feed(.user(text: "hi")), .ok)
    XCTAssertEqual(agent.traceLength, 1)
    guard case .llmRequest(let req)? = try agent.nextTypedEffect() else { return XCTFail("expected a request") }
    XCTAssertEqual(req.credential, "openai")
    XCTAssertEqual(req.auth, "bearer")
    XCTAssertFalse(agent.isDone)
  }

  func testSnapshotRestoreResumeReissuesRequest() throws {
    let agent = try Agent(config: localConfig)
    try agent.feed(.user(text: "hello"))
    let first = agent.effects()
    XCTAssertEqual(first.count, 1)
    let snap = agent.snapshot()

    let restored = try Agent(snapshot: snap)
    XCTAssertEqual(try restored.feed(.resume), .ok)
    guard case .llmRequest(let again)? = try restored.nextTypedEffect(),
      case .llmRequest(let orig) = try Effect(json: first[0])
    else { return XCTFail("expected the request to be re-issued") }
    XCTAssertEqual(again.body, orig.body)
    try restored.feed(.llmResponse(id: again.id, status: 200, body: textReply("Hi")))
    XCTAssertEqual(try restored.typedEffects(), [.complete(Completion(reason: "final", answer: "Hi", detail: nil))])
    XCTAssertFalse(restored.isDone, "a final answer leaves the run open for another user turn")
    XCTAssertFalse(restored.trace().isEmpty)
    XCTAssertFalse(restored.audit().isEmpty)
  }

  /// The async driver against a scripted fake transport: model asks for a host tool, gets its
  /// result, then answers. No network; the credential is only ever named.
  func testAsyncDriverWithFakeTransport() async throws {
    let rec = Recorder()
    let agent = try Agent(config: localConfig)
    let transport: LLMTransport = { req in
      switch rec.request(req) {
      case 1: return .complete(body: toolReply(id: "w1", name: "web_fetch", args: ["url": "https://example.com"]))
      case 2: return .complete(body: textReply("The page says hello."))
      case 3: return .complete(body: textReply("You're welcome."))
      default: return .complete(status: 500, body: "unexpected request")
      }
    }
    let fetch: ToolHandler = { call in
      rec.tool(call)
      return .string("hello from \(call.args["url"]?.stringValue ?? "?")")
    }
    let answer = try await agent.run(
      user: "what does the page say?", transport: transport, tools: ["net.fetch": fetch],
      onUI: { rec.ui($0) })

    XCTAssertEqual(answer, "The page says hello.")
    XCTAssertEqual(rec.requests.count, 2)
    XCTAssertEqual(rec.requests.map(\.id), ["r1", "r2"])
    XCTAssertTrue(rec.requests.allSatisfy { $0.credential == "openai" && $0.auth == "bearer" })
    XCTAssertTrue(rec.requests[1].body.contains("hello from https://example.com"))
    XCTAssertEqual(rec.tools.map(\.name), ["web_fetch"])
    XCTAssertEqual(rec.tools.first?.hostID, "net.fetch")
    XCTAssertEqual(rec.uiEvents, [.toolStart(id: "w1", name: "web_fetch"), .toolEnd(id: "w1", name: "web_fetch", ok: true)])
    XCTAssertFalse(agent.isDone, "a final answer leaves the run open for another user turn")
    // The same agent takes the next user turn.
    let second = try await agent.run(user: "thanks", transport: transport)
    XCTAssertEqual(second, "You're welcome.")

    // The URLRequest helper injects the host's secret per the effect's auth scheme.
    let r = try rec.requests[0].urlRequest(secret: "sk-test")
    XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    XCTAssertEqual(r.httpMethod, "POST")
    XCTAssertFalse(String(decoding: agent.trace(), as: UTF8.self).contains("sk-test"))
  }

  /// Streamed responses become chunk events and UI text deltas.
  func testAsyncDriverStreaming() async throws {
    let rec = Recorder()
    let agent = try Agent(config: ["agent": "assistant", "model": "m", "endpoint": "http://localhost/v1/chat/completions", "stream": true])
    let sse = [
      "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n\nda",
      "ta: {\"choices\":[{\"delta\":{\"content\":\"lo w\u{f6}rld\"}}]}\n\ndata: [DONE]\n\n",
    ]
    let transport: LLMTransport = { req in
      _ = rec.request(req)
      XCTAssertTrue(req.stream)
      return .stream(AsyncThrowingStream { c in
        for s in sse { c.yield(Data(s.utf8)) }
        c.finish()
      })
    }
    let answer = try await agent.run(user: "stream please", transport: transport, onUI: { rec.ui($0) })
    XCTAssertEqual(answer, "Hello w\u{f6}rld")
    XCTAssertEqual(rec.uiEvents, [.textDelta("Hel"), .textDelta("lo w\u{f6}rld")])
  }

  /// A run that ends other than `final` throws `runEnded`; a missing tool handler and a transport
  /// failure reach the agent as events instead of escaping.
  func testAsyncDriverNonFinalEndings() async throws {
    let halted = try Agent(config: localConfig)
    do {
      _ = try await halted.run(user: "wipe", transport: { _ in
        .complete(body: toolReply(id: "d", name: "delete_all", args: ["scope": "all"]))
      })
      XCTFail("expected runEnded")
    } catch AgentError.runEnded(let c) {
      XCTAssertEqual(c.reason, "policy_halt")
    }
    XCTAssertTrue(halted.isDone, "any ending but a final answer ends the run")

    struct Offline: Error {}
    let failing = try Agent(config: localConfig)
    do {
      _ = try await failing.run(user: "hi", transport: { _ in throw Offline() })
      XCTFail("expected runEnded")
    } catch AgentError.runEnded(let c) {
      XCTAssertEqual(c.reason, "error")
      XCTAssertTrue(c.detail?.contains("Offline") ?? false, c.detail ?? "")
    }

    let rec = Recorder()
    let noTool = try Agent(config: localConfig)
    let answer = try await noTool.run(user: "fetch", transport: { req in
      rec.request(req) == 1
        ? .complete(body: toolReply(id: "w1", name: "web_fetch", args: ["url": "u"]))
        : .complete(body: textReply("could not fetch"))
    }, onUI: { rec.ui($0) })
    XCTAssertEqual(answer, "could not fetch")
    XCTAssertTrue(rec.uiEvents.contains(.toolEnd(id: "w1", name: "web_fetch", ok: false)))
  }
}
