import Foundation

/// A loss-free, `Sendable` JSON tree for the parts of ArcGIS responses we keep verbatim
/// (domains, tile info, renderer) or probe loosely rather than model in full.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrecognised JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var isNull: Bool { self == .null }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? { if case .number(let d) = self { return d }; return nil }
    public var intValue: Int? { doubleValue.flatMap { Int(exactly: $0) } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
}

/// Decodes a number that ArcGIS may emit as a JSON number, a numeric string, or the string
/// `"NaN"` (empty extents). `NaN`, infinities, and unparseable strings decode as nil.
struct LenientDouble: Decodable, Sendable, Equatable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil; return }
        if let d = try? c.decode(Double.self) { value = d.isFinite ? d : nil; return }
        if let s = try? c.decode(String.self) {
            if let d = Double(s.trimmingCharacters(in: .whitespaces)), d.isFinite { value = d } else { value = nil }
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "expected a number or numeric string")
    }
}

extension KeyedDecodingContainer {
    /// Decodes a lenient double at `key`, treating a missing key, null, NaN, or junk as nil.
    func lenientDouble(_ key: Key) throws -> Double? {
        try decodeIfPresent(LenientDouble.self, forKey: key)?.value
    }
}
