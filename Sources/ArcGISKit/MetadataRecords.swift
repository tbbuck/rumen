import Foundation
import DuckDBKit

// Rows of the app database (SPEC §7.2) as Swift values. Timestamps are read with
// `epoch_us(...)` so they arrive as integers, never as parsed strings.

public struct ServerRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let rootURL: URL
    public var friendlyName: String
    public var originOverride: String?
    public var refererOverride: String?
    public var authKind: String
    public var username: String?
    public var tokenServiceURL: String?
    public var arcgisVersion: Double?
    public let createdAt: Date
    public var lastVisitedAt: Date?
    public var lastDeepCrawlAt: Date?

    public var headers: ServerHeaders {
        .resolve(rootURL: rootURL, originOverride: originOverride, refererOverride: refererOverride)
    }

    /// The connection for this server; the token (from the Keychain) is supplied by the caller.
    public func connection(token: String? = nil) -> ServerConnection {
        ServerConnection(rootURL: rootURL, headers: headers, token: token)
    }
}

public struct ServiceRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let serverID: Int64
    public let folderPath: String
    public let name: String
    public let type: ServiceType
    public let url: URL
    public var capabilities: String?
    public var maxRecordCount: Int?
    public var supportedQueryFormats: String?
    public var isTileCache: Bool?
    public var fetchedAt: Date?

    /// The last path component of `name` (`"Folder/Name"` → `"Name"`).
    public var shortName: String { name.split(separator: "/").last.map(String.init) ?? name }
    public var capabilitySet: Set<String> { Capabilities.parse(capabilities) }
    /// True once the service's own JSON has been fetched (not just its directory entry).
    public var isCrawled: Bool { fetchedAt != nil }
}

public struct LayerRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let serviceID: Int64
    public let layerID: Int
    public var name: String
    public var type: String?
    public var isTable: Bool
    public var geometryType: String?
    public var parentLayerID: Int?
    public var objectIdField: String?
    public var globalIdField: String?
    public var hasZ: Bool?
    public var hasM: Bool?
    public var hasAttachments: Bool?
    public var extentJSON: String?
    public var wkid: Int?
    public var latestWkid: Int?
    public var maxRecordCount: Int?
    public var supportedQueryFormats: String?
    public var capabilities: String?
    public var supportsPagination: Bool?
    public var supportsStatistics: Bool?
    public var supportsOrderBy: Bool?
    public var supportsResultType: Bool?
    public var transport: String?
    public var extractable: Bool?
    public var extractableReason: String?
    public var siblingLayerID: Int64?
    public var featureCount: Int64?
    public var featureCountAt: Date?
    public var fetchedAt: Date?

    public var queryFormats: Set<String> { Set(Capabilities.parse(supportedQueryFormats).map { $0.uppercased() }) }
    public var capabilitySet: Set<String> { Capabilities.parse(capabilities) }
    /// True once the layer's own definition (fields, capabilities) has been fetched.
    public var isCrawled: Bool { fetchedAt != nil }
    public var effectiveWkid: Int? { latestWkid ?? wkid }
}

public struct FieldRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let layerID: Int64
    public let position: Int
    public let name: String
    public let alias: String?
    public let esriType: EsriFieldType
    public let duckType: String
    public let length: Int?
    public let nullable: Bool?
    public let editable: Bool?
    public let domainJSON: String?
}

// MARK: - Row decoding helpers

extension DuckValue {
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .uint(let u): return Double(u)
        default: return nil
        }
    }
    var intValue: Int? { int64.map(Int.init) }
    /// Microseconds since the epoch (from `epoch_us(col)`) → Date.
    var dateFromMicros: Date? { int64.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) } }
}

extension Date {
    /// Microseconds since the Unix epoch, for `BindValue.timestamp`.
    var epochMicros: Int64 { Int64((timeIntervalSince1970 * 1_000_000).rounded()) }
    var bindValue: BindValue { .timestamp(micros: epochMicros) }
}

extension Optional where Wrapped == Date {
    var bindValue: BindValue { self.map { .timestamp(micros: $0.epochMicros) } ?? .null }
}
