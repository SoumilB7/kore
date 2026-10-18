import Foundation

/// Loosely typed JSON. The CLI's stream-json protocol is wide and keeps growing,
/// so we decode the handful of fields we need and keep the rest as-is.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, a.indices.contains(index) { a[index] } else { nil }
    }

    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var double: Double? { if case .number(let n) = self { n } else { nil } }
    public var int: Int? { double.map { Int($0) } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    /// Through Foundation's `JSONSerialization`: several times faster than decoding through
    /// `Codable`, which tries each type in turn at every level (a 61 MB transcript took seconds).
    public static func parse(_ data: Data) throws -> JSONValue {
        JSONValue(foundation: try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(foundation value: Any) {
        switch value {
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]: self = .array(array.map(JSONValue.init(foundation:)))
        case let object as [String: Any]: self = .object(object.mapValues(JSONValue.init(foundation:)))
        default: self = .null
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Compact single-line rendering, for logs and debugging.
    /// Keys are sorted, so the same value reads the same in every run.
    public var compact: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "<invalid json>"
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
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
        // Whole numbers go out as integers: JSON-RPC ids must round-trip as `0`, not `0.0`.
        case .number(let n) where n.rounded() == n && abs(n) < 1e15: try c.encode(Int64(n))
        case .number(let n): try c.encode(n)
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
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}
