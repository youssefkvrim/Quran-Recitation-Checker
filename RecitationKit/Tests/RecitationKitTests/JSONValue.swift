import Foundation

/// Exact JSON for tests. Linux `JSONSerialization` mis-rounds some doubles
/// (0.10000000149011612 parses 3 ulps off); `JSONDecoder` is correctly rounded.
enum JSONValue: Equatable, Decodable, CustomStringConvertible {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null }
    else if let b = try? c.decode(Bool.self) { self = .bool(b) }
    else if let d = try? c.decode(Double.self) { self = .number(d) }
    else if let s = try? c.decode(String.self) { self = .string(s) }
    else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
    else { self = .object(try c.decode([String: JSONValue].self)) }
  }

  /// From Swift literals built by the tests (`[String: Any]` etc.).
  init(_ any: Any?) {
    switch any {
    case nil, is NSNull: self = .null
    case let v as JSONValue: self = v
    case let b as Bool: self = .bool(b)
    case let i as Int: self = .number(Double(i))
    case let d as Double: self = .number(d)
    case let s as String: self = .string(s)
    case let a as [Any]: self = .array(a.map { JSONValue($0) })
    case let o as [String: Any]: self = .object(o.mapValues { JSONValue($0) })
    default: fatalError("unsupported JSON value \(String(describing: any))")
    }
  }

  static func load(_ url: URL) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
  }

  subscript(key: String) -> JSONValue { if case let .object(o) = self { return o[key] ?? .null }; return .null }
  subscript(index: Int) -> JSONValue { if case let .array(a) = self { return a[index] }; return .null }

  var double: Double { if case let .number(d) = self { return d }; fatalError("not a number: \(self)") }
  var int: Int { Int(double) }
  var string: String { if case let .string(s) = self { return s }; fatalError("not a string: \(self)") }
  var stringOrNil: String? { if case let .string(s) = self { return s }; return nil }
  var bool: Bool { if case let .bool(b) = self { return b }; fatalError("not a bool: \(self)") }
  var array: [JSONValue] { if case let .array(a) = self { return a }; fatalError("not an array: \(self)") }
  var object: [String: JSONValue] { if case let .object(o) = self { return o }; fatalError("not an object: \(self)") }
  var isNull: Bool { self == .null }

  var description: String {
    switch self {
    case .null: return "null"
    case let .bool(b): return "\(b)"
    case let .number(d): return d == d.rounded() && abs(d) < 1e15 ? "\(Int(d))" : "\(d)"
    case let .string(s): return "\"\(s)\""
    case let .array(a): return "[" + a.map(\.description).joined(separator: ",") + "]"
    case let .object(o): return "{" + o.keys.sorted().map { "\"\($0)\":\(o[$0]!)" }.joined(separator: ",") + "}"
    }
  }
}
