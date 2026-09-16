import Foundation

/// A feature attribute as delivered by either transport, typed enough to stage without loss:
/// integers stay 64-bit (JSON numbers that are whole become `.int`), dates arrive as epoch
/// milliseconds in `.int`.
public enum AttributeValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
    case bool(Bool)

    public init(_ json: JSONValue?) {
        switch json {
        case nil, .null?: self = .null
        case .bool(let b)?: self = .bool(b)
        case .string(let s)?: self = .string(s)
        case .number(let d)?:
            if d == d.rounded(), abs(d) < 9.0e15 { self = .int(Int64(d)) } else { self = .double(d) }
        case .array?, .object?:
            let data = (try? JSONEncoder().encode(json!)) ?? Data()
            self = .string(String(decoding: data, as: UTF8.self))
        }
    }

    public var isNull: Bool { self == .null }
    public var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d == d.rounded() && abs(d) < 9.0e18: return Int64(d)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        }
    }
}

/// One feature with attributes in field order, as both transports deliver it.
public struct DecodedFeature: Sendable, Equatable {
    public var attributes: [AttributeValue]
    public var geometry: EsriGeometry?

    public init(attributes: [AttributeValue], geometry: EsriGeometry?) {
        self.attributes = attributes
        self.geometry = geometry
    }
}

/// A page of features in a transport-neutral shape: what the download engine stages.
public struct FeaturePage: Sendable, Equatable {
    public let fields: [FieldInfo]
    public let features: [DecodedFeature]
    public let geometryType: String?
    public let wkid: Int?
    public let hasZ: Bool
    public let hasM: Bool
    public let exceededTransferLimit: Bool

    public init(fields: [FieldInfo], features: [DecodedFeature], geometryType: String?, wkid: Int?,
                hasZ: Bool, hasM: Bool, exceededTransferLimit: Bool) {
        self.fields = fields
        self.features = features
        self.geometryType = geometryType
        self.wkid = wkid
        self.hasZ = hasZ
        self.hasM = hasM
        self.exceededTransferLimit = exceededTransferLimit
    }

    /// From an Esri JSON feature set. Z/M presence is inferred from coordinate arity when the
    /// layer flags are not supplied.
    public init(json set: FeatureSet, hasZ: Bool? = nil, hasM: Bool? = nil) {
        let names = set.fields.map(\.name)
        let features = set.features.map { feature in
            DecodedFeature(attributes: names.map { AttributeValue(feature.attributes[$0]) }, geometry: feature.geometry)
        }
        let arity = features.lazy.compactMap { $0.geometry }.first.map(Self.arity) ?? 2
        self.init(fields: set.fields, features: features, geometryType: set.geometryType,
                  wkid: set.spatialReference?.effectiveWkid, hasZ: hasZ ?? (arity >= 3), hasM: hasM ?? (arity == 4),
                  exceededTransferLimit: set.exceededTransferLimit)
    }

    static func arity(_ g: EsriGeometry) -> Int {
        switch g {
        case .point(let c): return c.count
        case .multipoint(let p): return p.first?.count ?? 2
        case .polyline(let paths): return paths.first?.first?.count ?? 2
        case .polygon(let rings): return rings.first?.first?.count ?? 2
        case .envelope: return 2
        }
    }
}
