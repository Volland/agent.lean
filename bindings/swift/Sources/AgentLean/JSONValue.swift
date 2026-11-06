import Foundation

/// A JSON value: tool arguments, tool results and other free-form payloads that cross the ABI.
public enum JSONValue: Sendable, Hashable {
  case null
  case bool(Bool)
  case int(Int64)
  case double(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  /// Parse UTF-8 JSON bytes.
  public init(json data: Data) throws {
    self = try JSONDecoder().decode(JSONValue.self, from: data)
  }

  /// Compact JSON text, with object keys sorted so the output is deterministic.
  public var jsonString: String {
    var out = ""
    write(into: &out)
    return out
  }

  /// Compact JSON as UTF-8 bytes.
  public var jsonData: Data { Data(jsonString.utf8) }

  public subscript(key: String) -> JSONValue? {
    if case .object(let o) = self { return o[key] }
    return nil
  }

  public var stringValue: String? {
    if case .string(let s) = self { return s }
    return nil
  }

  public var intValue: Int64? {
    switch self {
    case .int(let i): return i
    case .double(let d) where d.rounded() == d && abs(d) < 9.2e18: return Int64(d)
    default: return nil
    }
  }

  public var boolValue: Bool? {
    if case .bool(let b) = self { return b }
    return nil
  }

  func write(into out: inout String) {
    switch self {
    case .null: out += "null"
    case .bool(let b): out += b ? "true" : "false"
    case .int(let i): out += String(i)
    case .double(let d): out += d.isFinite ? "\(d)" : "null"
    case .string(let s): JSONValue.writeString(s, into: &out)
    case .array(let a):
      out += "["
      for (i, v) in a.enumerated() {
        if i > 0 { out += "," }
        v.write(into: &out)
      }
      out += "]"
    case .object(let o):
      out += "{"
      for (i, k) in o.keys.sorted().enumerated() {
        if i > 0 { out += "," }
        JSONValue.writeString(k, into: &out)
        out += ":"
        o[k]!.write(into: &out)
      }
      out += "}"
    }
  }

  static func writeString(_ s: String, into out: inout String) {
    out += "\""
    for u in s.unicodeScalars {
      switch u {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      case "\r": out += "\\r"
      case "\t": out += "\\t"
      case _ where u.value < 0x20:
        out += "\\u00"
        out += String(u.value >> 4, radix: 16)
        out += String(u.value & 0xF, radix: 16)
      default: out.unicodeScalars.append(u)
      }
    }
    out += "\""
  }
}

extension JSONValue: Codable {
  public init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() {
      self = .null
    } else if let b = try? c.decode(Bool.self) {
      self = .bool(b)
    } else if let i = try? c.decode(Int64.self) {
      self = .int(i)
    } else if let d = try? c.decode(Double.self) {
      self = .double(d)
    } else if let s = try? c.decode(String.self) {
      self = .string(s)
    } else if let a = try? c.decode([JSONValue].self) {
      self = .array(a)
    } else {
      self = .object(try c.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let b): try c.encode(b)
    case .int(let i): try c.encode(i)
    case .double(let d): try c.encode(d)
    case .string(let s): try c.encode(s)
    case .array(let a): try c.encode(a)
    case .object(let o): try c.encode(o)
    }
  }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
  ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
  ExpressibleByDictionaryLiteral
{
  public init(nilLiteral: ()) { self = .null }
  public init(booleanLiteral value: Bool) { self = .bool(value) }
  public init(integerLiteral value: Int64) { self = .int(value) }
  public init(floatLiteral value: Double) { self = .double(value) }
  public init(stringLiteral value: String) { self = .string(value) }
  public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
  public init(dictionaryLiteral elements: (String, JSONValue)...) {
    self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
  }
}
