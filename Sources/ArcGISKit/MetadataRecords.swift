import Foundation
import SQLiteKit

// Rows of the app database (SPEC §7.2) as Swift values. Timestamps are INTEGER microseconds
// since the Unix epoch in SQLite, so they arrive as integers, never as parsed strings. Explicit
// initialisers keep them constructible from tests and previews.

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

    public init(id: Int64, rootURL: URL, friendlyName: String, originOverride: String? = nil,
                refererOverride: String? = nil, authKind: String = "none", username: String? = nil,
                tokenServiceURL: String? = nil, arcgisVersion: Double? = nil, createdAt: Date = Date(),
                lastVisitedAt: Date? = nil, lastDeepCrawlAt: Date? = nil) {
        self.id = id
        self.rootURL = rootURL
        self.friendlyName = friendlyName
        self.originOverride = originOverride
        self.refererOverride = refererOverride
        self.authKind = authKind
        self.username = username
        self.tokenServiceURL = tokenServiceURL
        self.arcgisVersion = arcgisVersion
        self.createdAt = createdAt
        self.lastVisitedAt = lastVisitedAt
        self.lastDeepCrawlAt = lastDeepCrawlAt
    }

    public var headers: ServerHeaders {
        .resolve(rootURL: rootURL, originOverride: originOverride, refererOverride: refererOverride)
    }

    /// The connection for this server; the token (from the Keychain) is supplied by the caller.
    public func connection(token: String? = nil, cookie: String? = nil) -> ServerConnection {
        ServerConnection(rootURL: rootURL, headers: headers, token: token, cookie: cookie)
    }

    /// The host shown in the path bar and as the default friendly name.
    public var host: String { rootURL.host ?? rootURL.absoluteString }
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
    public var extentWGS84: BoundingBox?
    public var fetchedAt: Date?

    public init(id: Int64, serverID: Int64, folderPath: String = "", name: String, type: ServiceType, url: URL,
                capabilities: String? = nil, maxRecordCount: Int? = nil, supportedQueryFormats: String? = nil,
                isTileCache: Bool? = nil, extentWGS84: BoundingBox? = nil, fetchedAt: Date? = nil) {
        self.id = id
        self.serverID = serverID
        self.folderPath = folderPath
        self.name = name
        self.type = type
        self.url = url
        self.capabilities = capabilities
        self.maxRecordCount = maxRecordCount
        self.supportedQueryFormats = supportedQueryFormats
        self.isTileCache = isTileCache
        self.extentWGS84 = extentWGS84
        self.fetchedAt = fetchedAt
    }

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
    public var extentWGS84: BoundingBox?
    public var fetchedAt: Date?

    public init(id: Int64, serviceID: Int64, layerID: Int, name: String, type: String? = nil, isTable: Bool = false,
                geometryType: String? = nil, parentLayerID: Int? = nil, objectIdField: String? = nil,
                globalIdField: String? = nil, hasZ: Bool? = nil, hasM: Bool? = nil, hasAttachments: Bool? = nil,
                extentJSON: String? = nil, wkid: Int? = nil, latestWkid: Int? = nil, maxRecordCount: Int? = nil,
                supportedQueryFormats: String? = nil, capabilities: String? = nil, supportsPagination: Bool? = nil,
                supportsStatistics: Bool? = nil, supportsOrderBy: Bool? = nil, supportsResultType: Bool? = nil,
                transport: String? = nil, extractable: Bool? = nil, extractableReason: String? = nil,
                siblingLayerID: Int64? = nil, featureCount: Int64? = nil, featureCountAt: Date? = nil,
                extentWGS84: BoundingBox? = nil, fetchedAt: Date? = nil) {
        self.id = id
        self.serviceID = serviceID
        self.layerID = layerID
        self.name = name
        self.type = type
        self.isTable = isTable
        self.geometryType = geometryType
        self.parentLayerID = parentLayerID
        self.objectIdField = objectIdField
        self.globalIdField = globalIdField
        self.hasZ = hasZ
        self.hasM = hasM
        self.hasAttachments = hasAttachments
        self.extentJSON = extentJSON
        self.wkid = wkid
        self.latestWkid = latestWkid
        self.maxRecordCount = maxRecordCount
        self.supportedQueryFormats = supportedQueryFormats
        self.capabilities = capabilities
        self.supportsPagination = supportsPagination
        self.supportsStatistics = supportsStatistics
        self.supportsOrderBy = supportsOrderBy
        self.supportsResultType = supportsResultType
        self.transport = transport
        self.extractable = extractable
        self.extractableReason = extractableReason
        self.siblingLayerID = siblingLayerID
        self.featureCount = featureCount
        self.featureCountAt = featureCountAt
        self.extentWGS84 = extentWGS84
        self.fetchedAt = fetchedAt
    }

    public var queryFormats: Set<String> { Set(Capabilities.parse(supportedQueryFormats).map { $0.uppercased() }) }
    public var capabilitySet: Set<String> { Capabilities.parse(capabilities) }
    /// True once the layer's own definition (fields, capabilities) has been fetched.
    public var isCrawled: Bool { fetchedAt != nil }
    public var effectiveWkid: Int? { latestWkid ?? wkid }

    /// The native extent parsed back from `extentJSON`, if stored.
    public var nativeExtent: (xmin: Double, ymin: Double, xmax: Double, ymax: Double)? {
        guard let json = extentJSON, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let xmin = object["xmin"] as? Double, let ymin = object["ymin"] as? Double,
              let xmax = object["xmax"] as? Double, let ymax = object["ymax"] as? Double else { return nil }
        return (xmin, ymin, xmax, ymax)
    }
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

    public init(id: Int64, layerID: Int64, position: Int, name: String, alias: String? = nil, esriType: EsriFieldType,
                duckType: String, length: Int? = nil, nullable: Bool? = nil, editable: Bool? = nil,
                domainJSON: String? = nil) {
        self.id = id
        self.layerID = layerID
        self.position = position
        self.name = name
        self.alias = alias
        self.esriType = esriType
        self.duckType = duckType
        self.length = length
        self.nullable = nullable
        self.editable = editable
        self.domainJSON = domainJSON
    }

    /// `esriFieldTypeString` → `String`, with the length for strings (`String 256`).
    public var shortEsriType: String {
        let base = esriType.rawValue.hasPrefix("esriFieldType") ? String(esriType.rawValue.dropFirst("esriFieldType".count)) : esriType.rawValue
        if esriType == .string, let length { return "\(base) \(length)" }
        return base
    }

    /// Coded values as "code name, code name…" for a domain cell; nil when not a coded domain.
    public var codedValuesSummary: String? {
        guard let json = domainJSON, let data = json.data(using: .utf8),
              let domain = try? JSONDecoder().decode(JSONValue.self, from: data),
              domain["type"]?.stringValue == "codedValue",
              let values = domain["codedValues"]?.arrayValue, !values.isEmpty else { return nil }
        return values.compactMap { v -> String? in
            guard let name = v["name"]?.stringValue else { return nil }
            let code = v["code"]?.stringValue ?? v["code"]?.intValue.map(String.init) ?? v["code"]?.doubleValue.map { String($0) } ?? ""
            return code.isEmpty ? name : "\(code) \(name)"
        }.joined(separator: ", ")
    }
}

// MARK: - Bind helpers

extension Date {
    /// Microseconds since the Unix epoch, for `BindValue.timestamp`.
    var epochMicros: Int64 { Int64((timeIntervalSince1970 * 1_000_000).rounded()) }
    var bindValue: SQLBind { .timestamp(micros: epochMicros) }
}

extension Optional where Wrapped == Date {
    var bindValue: SQLBind { self.map { .timestamp(micros: $0.epochMicros) } ?? .null }
}
