import Foundation

// Decodable views over ArcGIS REST JSON. Every field the server might omit is optional; the
// raw JSON is stored alongside (SPEC §5.2) so nothing modelled here is the only copy.

/// `…/rest/services?f=json` (and a folder's listing, which has the same shape).
public struct ServiceDirectory: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        /// As listed: `"Name"` at the root, `"Folder/Name"` inside a folder.
        public let name: String
        public let type: String
        public var serviceType: ServiceType { ServiceType(type) }

        public init(name: String, type: String) {
            self.name = name
            self.type = type
        }
    }

    public let currentVersion: Double?
    public let folders: [String]
    public let services: [Entry]

    private enum CodingKeys: String, CodingKey { case currentVersion, folders, services }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentVersion = try c.lenientDouble(.currentVersion)
        folders = try c.decodeIfPresent([String].self, forKey: .folders) ?? []
        services = try c.decodeIfPresent([Entry].self, forKey: .services) ?? []
    }

    public init(currentVersion: Double? = nil, folders: [String] = [], services: [Entry] = []) {
        self.currentVersion = currentVersion
        self.folders = folders
        self.services = services
    }

    /// Nothing listed at all. Distinguishing "told us nothing" from "told us it is empty" is
    /// the caller's job: see `ArcGISClient.serviceDirectory`.
    public var isEmpty: Bool { folders.isEmpty && services.isEmpty }
}

public struct SpatialReference: Decodable, Sendable, Equatable {
    public let wkid: Int?
    public let latestWkid: Int?
    public let wkt: String?

    /// The id to report: `latestWkid` when present (e.g. 3857 over 102100), else `wkid`.
    public var effectiveWkid: Int? { latestWkid ?? wkid }
}

/// An envelope. ArcGIS emits `"NaN"` strings for the extent of an empty layer, so any
/// coordinate can be nil; `isEmpty` is true when any is.
public struct Extent: Decodable, Sendable, Equatable {
    public let xmin: Double?
    public let ymin: Double?
    public let xmax: Double?
    public let ymax: Double?
    public let spatialReference: SpatialReference?

    private enum CodingKeys: String, CodingKey { case xmin, ymin, xmax, ymax, spatialReference }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        xmin = try c.lenientDouble(.xmin)
        ymin = try c.lenientDouble(.ymin)
        xmax = try c.lenientDouble(.xmax)
        ymax = try c.lenientDouble(.ymax)
        spatialReference = try c.decodeIfPresent(SpatialReference.self, forKey: .spatialReference)
    }

    public var isEmpty: Bool { xmin == nil || ymin == nil || xmax == nil || ymax == nil }
}

/// A layer or table as summarised in a service's `layers` / `tables` arrays.
public struct LayerSummary: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let type: String?
    public let geometryType: String?
    public let parentLayerId: Int?
    public let subLayerIds: [Int]?

    public init(id: Int, name: String, type: String? = nil, geometryType: String? = nil,
                parentLayerId: Int? = nil, subLayerIds: [Int]? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.geometryType = geometryType
        self.parentLayerId = parentLayerId
        self.subLayerIds = subLayerIds
    }

    /// ArcGIS uses -1 for "no parent".
    public var parentID: Int? { parentLayerId.flatMap { $0 >= 0 ? $0 : nil } }
}

/// `…/<Name>/MapServer?f=json` or `…/FeatureServer?f=json`.
public struct ServiceInfo: Decodable, Sendable, Equatable {
    public let currentVersion: Double?
    public let serviceDescription: String?
    public let description: String?
    public let mapName: String?
    public let copyrightText: String?
    public let capabilities: String?
    public let supportedQueryFormats: String?
    public let maxRecordCount: Int?
    public let singleFusedMapCache: Bool?
    public let tileInfo: JSONValue?
    public let exportTilesAllowed: Bool?
    public let supportsDynamicLayers: Bool?
    public let spatialReference: SpatialReference?
    public let fullExtent: Extent?
    public let layers: [LayerSummary]
    public let tables: [LayerSummary]

    private enum CodingKeys: String, CodingKey {
        case currentVersion, serviceDescription, description, mapName, copyrightText, capabilities,
             supportedQueryFormats, maxRecordCount, singleFusedMapCache, tileInfo, exportTilesAllowed,
             supportsDynamicLayers, spatialReference, fullExtent, layers, tables
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        currentVersion = try c.lenientDouble(.currentVersion)
        serviceDescription = try c.decodeIfPresent(String.self, forKey: .serviceDescription)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        mapName = try c.decodeIfPresent(String.self, forKey: .mapName)
        copyrightText = try c.decodeIfPresent(String.self, forKey: .copyrightText)
        capabilities = try c.decodeIfPresent(String.self, forKey: .capabilities)
        supportedQueryFormats = try c.decodeIfPresent(String.self, forKey: .supportedQueryFormats)
        maxRecordCount = try c.decodeIfPresent(Int.self, forKey: .maxRecordCount)
        singleFusedMapCache = try c.decodeIfPresent(Bool.self, forKey: .singleFusedMapCache)
        tileInfo = try c.decodeIfPresent(JSONValue.self, forKey: .tileInfo)
        exportTilesAllowed = try c.decodeIfPresent(Bool.self, forKey: .exportTilesAllowed)
        supportsDynamicLayers = try c.decodeIfPresent(Bool.self, forKey: .supportsDynamicLayers)
        spatialReference = try c.decodeIfPresent(SpatialReference.self, forKey: .spatialReference)
        fullExtent = try c.decodeIfPresent(Extent.self, forKey: .fullExtent)
        layers = try c.decodeIfPresent([LayerSummary].self, forKey: .layers) ?? []
        tables = try c.decodeIfPresent([LayerSummary].self, forKey: .tables) ?? []
    }

    /// A cached (pre-rendered tile) map service. Its layers are drawn from tiles, and are
    /// only queryable if the service also lists `Query`.
    public var isTileCache: Bool { singleFusedMapCache == true || tileInfo != nil }

    public var capabilitySet: Set<String> { Capabilities.parse(capabilities) }
}

/// An Esri field type. A struct rather than an enum so unknown future types still decode.
public struct EsriFieldType: RawRepresentable, Sendable, Equatable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let oid = EsriFieldType(rawValue: "esriFieldTypeOID")
    public static let smallInteger = EsriFieldType(rawValue: "esriFieldTypeSmallInteger")
    public static let integer = EsriFieldType(rawValue: "esriFieldTypeInteger")
    public static let bigInteger = EsriFieldType(rawValue: "esriFieldTypeBigInteger")
    public static let single = EsriFieldType(rawValue: "esriFieldTypeSingle")
    public static let double = EsriFieldType(rawValue: "esriFieldTypeDouble")
    public static let string = EsriFieldType(rawValue: "esriFieldTypeString")
    public static let date = EsriFieldType(rawValue: "esriFieldTypeDate")
    public static let dateOnly = EsriFieldType(rawValue: "esriFieldTypeDateOnly")
    public static let timeOnly = EsriFieldType(rawValue: "esriFieldTypeTimeOnly")
    public static let timestampOffset = EsriFieldType(rawValue: "esriFieldTypeTimestampOffset")
    public static let guid = EsriFieldType(rawValue: "esriFieldTypeGUID")
    public static let globalID = EsriFieldType(rawValue: "esriFieldTypeGlobalID")
    public static let xml = EsriFieldType(rawValue: "esriFieldTypeXML")
    public static let blob = EsriFieldType(rawValue: "esriFieldTypeBlob")
    public static let raster = EsriFieldType(rawValue: "esriFieldTypeRaster")
    public static let geometry = EsriFieldType(rawValue: "esriFieldTypeGeometry")

    /// The DuckDB column type this maps to (SPEC §5.6), or nil for types we skip (raster).
    /// Unknown types land as VARCHAR so nothing is lost.
    public var duckType: String? {
        switch self {
        case .oid, .bigInteger: return "BIGINT"
        case .integer: return "INTEGER"
        case .smallInteger: return "SMALLINT"
        case .double: return "DOUBLE"
        case .single: return "FLOAT"
        case .string, .xml: return "VARCHAR"
        case .date: return "TIMESTAMP"
        case .dateOnly: return "DATE"
        case .timeOnly: return "TIME"
        case .timestampOffset: return "TIMESTAMPTZ"
        case .guid, .globalID: return "UUID"
        case .blob: return "BLOB"
        case .geometry: return "GEOMETRY"
        case .raster: return nil
        default: return "VARCHAR"
        }
    }
}

public struct FieldInfo: Decodable, Sendable, Equatable {
    public let name: String
    public let type: EsriFieldType
    public let alias: String?
    public let length: Int?
    public let nullable: Bool?
    public let editable: Bool?
    /// Verbatim domain (`codedValue`, `range`, `inherited`); nil when absent or JSON null.
    public let domain: JSONValue?
    public let defaultValue: JSONValue?

    /// `[(code, name)]` for a coded-value domain, else nil. Codes keep their JSON type
    /// (number or string) because that is how they appear in attribute values.
    public var codedValues: [(code: JSONValue, name: String)]? {
        guard let domain, domain["type"]?.stringValue == "codedValue",
              let values = domain["codedValues"]?.arrayValue else { return nil }
        return values.compactMap { v in
            guard let code = v["code"], let name = v["name"]?.stringValue else { return nil }
            return (code, name)
        }
    }
}

public struct LayerReference: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String?
}

/// The `advancedQueryCapabilities` block. All optional: older servers omit the block or
/// individual flags, and absence means "no".
public struct AdvancedQueryCapabilities: Decodable, Sendable, Equatable {
    public let supportsPagination: Bool?
    public let supportsStatistics: Bool?
    public let supportsOrderBy: Bool?
    public let supportsDistinct: Bool?
    public let supportsQueryWithResultType: Bool?
    public let supportsReturningQueryExtent: Bool?
    public let supportsSqlExpression: Bool?
    public let supportsMaxRecordCountFactor: Bool?
    public let supportsCountDistinct: Bool?
    public let supportsReturningGeometryCentroid: Bool?
}

/// `…/MapServer/<id>?f=json` or `…/FeatureServer/<id>?f=json`; also each element of the
/// bulk `…/layers?f=json` response.
public struct LayerInfo: Decodable, Sendable, Equatable {
    public let id: Int
    public let name: String
    public let type: String?
    public let geometryType: String?
    public let description: String?
    public let objectIdField: String?
    public let globalIdField: String?
    public let displayField: String?
    public let hasZ: Bool?
    public let hasM: Bool?
    public let hasAttachments: Bool?
    public let extent: Extent?
    public let sourceSpatialReference: SpatialReference?
    public let maxRecordCount: Int?
    public let standardMaxRecordCount: Int?
    public let tileMaxRecordCount: Int?
    public let maxRecordCountFactor: Int?
    public let supportedQueryFormats: String?
    public let capabilities: String?
    public let supportsStatistics: Bool?
    public let supportsAdvancedQueries: Bool?
    /// Legacy top-level flag (10.1–10.2); newer servers put it in `advancedQueryCapabilities`.
    public let supportsPagination: Bool?
    public let supportsCoordinatesQuantization: Bool?
    public let advancedQueryCapabilities: AdvancedQueryCapabilities?
    public let fields: [FieldInfo]
    public let parentLayer: LayerReference?
    public let subLayers: [LayerReference]?
    public let relationships: [JSONValue]?
    public let editingInfo: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case id, name, type, geometryType, description, objectIdField, globalIdField, displayField,
             hasZ, hasM, hasAttachments, extent, sourceSpatialReference, maxRecordCount,
             standardMaxRecordCount, tileMaxRecordCount, maxRecordCountFactor, supportedQueryFormats,
             capabilities, supportsStatistics, supportsAdvancedQueries, supportsPagination,
             supportsCoordinatesQuantization, advancedQueryCapabilities, fields, parentLayer,
             subLayers, relationships, editingInfo
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        geometryType = try c.decodeIfPresent(String.self, forKey: .geometryType)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        objectIdField = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .objectIdField))
        globalIdField = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .globalIdField))
        displayField = Self.blankToNil(try c.decodeIfPresent(String.self, forKey: .displayField))
        hasZ = try c.decodeIfPresent(Bool.self, forKey: .hasZ)
        hasM = try c.decodeIfPresent(Bool.self, forKey: .hasM)
        hasAttachments = try c.decodeIfPresent(Bool.self, forKey: .hasAttachments)
        extent = try c.decodeIfPresent(Extent.self, forKey: .extent)
        sourceSpatialReference = try c.decodeIfPresent(SpatialReference.self, forKey: .sourceSpatialReference)
        maxRecordCount = try c.decodeIfPresent(Int.self, forKey: .maxRecordCount)
        standardMaxRecordCount = try c.decodeIfPresent(Int.self, forKey: .standardMaxRecordCount)
        tileMaxRecordCount = try c.decodeIfPresent(Int.self, forKey: .tileMaxRecordCount)
        maxRecordCountFactor = try c.decodeIfPresent(Int.self, forKey: .maxRecordCountFactor)
        supportedQueryFormats = try c.decodeIfPresent(String.self, forKey: .supportedQueryFormats)
        capabilities = try c.decodeIfPresent(String.self, forKey: .capabilities)
        supportsStatistics = try c.decodeIfPresent(Bool.self, forKey: .supportsStatistics)
        supportsAdvancedQueries = try c.decodeIfPresent(Bool.self, forKey: .supportsAdvancedQueries)
        supportsPagination = try c.decodeIfPresent(Bool.self, forKey: .supportsPagination)
        supportsCoordinatesQuantization = try c.decodeIfPresent(Bool.self, forKey: .supportsCoordinatesQuantization)
        advancedQueryCapabilities = try c.decodeIfPresent(AdvancedQueryCapabilities.self, forKey: .advancedQueryCapabilities)
        fields = try c.decodeIfPresent([FieldInfo].self, forKey: .fields) ?? []
        parentLayer = try c.decodeIfPresent(LayerReference.self, forKey: .parentLayer)
        subLayers = try c.decodeIfPresent([LayerReference].self, forKey: .subLayers)
        relationships = try c.decodeIfPresent([JSONValue].self, forKey: .relationships)
        editingInfo = try c.decodeIfPresent(JSONValue.self, forKey: .editingInfo)
    }

    private static func blankToNil(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return s
    }

    /// The OID field name: the declared `objectIdField`, else the first `esriFieldTypeOID`
    /// field (ArcGIS Server MapServer layers often omit the property). Nil if neither exists.
    public var oidField: String? {
        objectIdField ?? fields.first { $0.type == .oid }?.name
    }

    /// True for a non-spatial table (`type == "Table"` or no geometry type on a feature-ish layer).
    public var isTable: Bool { type == "Table" || (type == "Feature Layer" && geometryType == nil) }

    /// Pagination support, preferring the modern block over the legacy flag. Absent means no.
    public var canPaginate: Bool {
        advancedQueryCapabilities?.supportsPagination ?? supportsPagination ?? false
    }

    /// Statistics support, preferring the modern block over the legacy flag.
    public var canStatistics: Bool {
        advancedQueryCapabilities?.supportsStatistics ?? supportsStatistics ?? false
    }

    public var canOrderBy: Bool { advancedQueryCapabilities?.supportsOrderBy ?? false }

    /// Upper-cased, trimmed entries of `supportedQueryFormats`, e.g. `["JSON", "GEOJSON", "PBF"]`.
    public var queryFormats: Set<String> { Capabilities.parse(supportedQueryFormats).map { $0.uppercased() }.reduce(into: []) { $0.insert($1) } }

    public var capabilitySet: Set<String> { Capabilities.parse(capabilities) }

    /// The layer's `sourceSpatialReference` if present, else its extent's.
    public var spatialReference: SpatialReference? { sourceSpatialReference ?? extent?.spatialReference }

    /// `editingInfo.lastEditDate` as epoch milliseconds, when the server tracks it.
    public var lastEditDateMillis: Int64? {
        editingInfo?["lastEditDate"]?.doubleValue.map { Int64($0) }
    }
}

/// `…/MapServer/layers?f=json`: every layer and table definition in one response.
public struct LayersResponse: Decodable, Sendable, Equatable {
    public let layers: [LayerInfo]
    public let tables: [LayerInfo]

    private enum CodingKeys: String, CodingKey { case layers, tables }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layers = try c.decodeIfPresent([LayerInfo].self, forKey: .layers) ?? []
        tables = try c.decodeIfPresent([LayerInfo].self, forKey: .tables) ?? []
    }
}

/// `query?returnCountOnly=true`.
public struct CountResponse: Decodable, Sendable, Equatable {
    public let count: Int
}

/// The `{"error": {...}}` body ArcGIS returns — with HTTP 200 — for every REST failure.
public struct ArcGISErrorEnvelope: Decodable, Sendable, Equatable {
    public struct Body: Decodable, Sendable, Equatable {
        public let code: Int?
        public let message: String?
        public let details: [String]?
    }
    public let error: Body
}

/// Parsing for comma-separated capability / format strings such as `"Map,Query,Data"` or
/// `"JSON, geoJSON, PBF"`.
public enum Capabilities {
    public static func parse(_ s: String?) -> Set<String> {
        guard let s else { return [] }
        return Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }
}

/// Shared JSON decoding for ArcGIS responses.
public enum ArcGISJSON {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    /// Returns the error envelope if `data` is one, else nil. Only a top-level `error` object
    /// counts; a layer named "error" or an `error` field inside a feature does not.
    public static func errorEnvelope(in data: Data) -> ArcGISErrorEnvelope? {
        guard let envelope = try? JSONDecoder().decode(ArcGISErrorEnvelope.self, from: data) else { return nil }
        return envelope
    }
}
