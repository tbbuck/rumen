import Foundation

/// One `outStatistics` entry.
public struct StatisticDefinition: Sendable, Equatable, Encodable {
    public enum Kind: String, Sendable, Encodable { case count, sum, min, max, avg, stddev, `var` }
    public let statisticType: Kind
    public let onStatisticField: String
    public let outStatisticFieldName: String

    public init(_ type: Kind, field: String, outName: String? = nil) {
        self.statisticType = type
        self.onStatisticField = field
        self.outStatisticFieldName = outName ?? "\(type.rawValue)_\(field)"
    }

    /// min / max / avg / count for numeric fields, min / max / count for dates — the overview
    /// statistics the Query tab runs in one request.
    public static func overview(for fields: [FieldRecord]) -> [StatisticDefinition] {
        var out = [StatisticDefinition]()
        for field in fields {
            switch field.esriType {
            case .integer, .smallInteger, .bigInteger, .double, .single:
                out += [.init(.min, field: field.name), .init(.max, field: field.name),
                        .init(.avg, field: field.name), .init(.count, field: field.name)]
            case .date:
                out += [.init(.min, field: field.name), .init(.max, field: field.name), .init(.count, field: field.name)]
            default: break
            }
        }
        return out
    }
}

/// Options for one `query` request, turned into ArcGIS parameters. `f` and `token` are the
/// client's business.
public struct QueryOptions: Sendable, Equatable {
    public var whereClause: String = "1=1"
    /// nil = all fields (`*`).
    public var outFields: [String]? = nil
    public var returnGeometry: Bool = true
    /// nil = the layer's native spatial reference.
    public var outWkid: Int? = nil
    public var orderBy: (field: String, ascending: Bool)? = nil
    public var offset: Int? = nil
    public var count: Int? = nil
    public var distinct: Bool = false
    public var statistics: [StatisticDefinition] = []
    /// `objectIds=`: fetch exactly these features (the OID-list strategy).
    public var objectIDs: [Int64]? = nil
    /// Decimal places for returned geometry (`geometryPrecision`); nil = server default.
    public var geometryPrecision: Int? = nil

    public init(whereClause: String = "1=1", outFields: [String]? = nil, returnGeometry: Bool = true,
                outWkid: Int? = nil, orderBy: (field: String, ascending: Bool)? = nil, offset: Int? = nil,
                count: Int? = nil, distinct: Bool = false, statistics: [StatisticDefinition] = []) {
        self.whereClause = whereClause
        self.outFields = outFields
        self.returnGeometry = returnGeometry
        self.outWkid = outWkid
        self.orderBy = orderBy
        self.offset = offset
        self.count = count
        self.distinct = distinct
        self.statistics = statistics
    }

    public static func == (a: QueryOptions, b: QueryOptions) -> Bool {
        a.params == b.params
    }

    public var params: [String: String] {
        var p = [String: String]()
        let trimmed = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        p["where"] = trimmed.isEmpty ? "1=1" : trimmed
        p["outFields"] = outFields.map { $0.isEmpty ? "*" : $0.joined(separator: ",") } ?? "*"
        let geometry = returnGeometry && !distinct && statistics.isEmpty
        p["returnGeometry"] = geometry ? "true" : "false"
        if let outWkid { p["outSR"] = String(outWkid) }
        if let orderBy { p["orderByFields"] = "\(orderBy.field) \(orderBy.ascending ? "ASC" : "DESC")" }
        if let offset { p["resultOffset"] = String(offset) }
        if let count { p["resultRecordCount"] = String(count) }
        if distinct { p["returnDistinctValues"] = "true" }
        if let objectIDs, !objectIDs.isEmpty { p["objectIds"] = objectIDs.map(String.init).joined(separator: ",") }
        if let geometryPrecision { p["geometryPrecision"] = String(geometryPrecision) }
        if !statistics.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]   // deterministic for tests and caching
            guard let data = try? encoder.encode(statistics) else { return p }
            p["outStatistics"] = String(decoding: data, as: UTF8.self)
        }
        return p
    }
}

extension ArcGISClient {
    /// Runs a feature query (page, distinct values, or statistics) and decodes the feature set.
    public func features(_ server: ServerConnection, layerURL: URL, options: QueryOptions,
                         maxAttempts: Int? = nil, progress: TransferProgressHandler? = nil) async throws -> (value: FeatureSet, raw: Data) {
        try await json(FeatureSet.self, .post, url: layerURL.appendingPathComponent("query"),
                       params: options.params, server: server, maxAttempts: maxAttempts, progress: progress)
    }

    /// `returnExtentOnly=true` for a where clause, optionally in another spatial reference.
    public func extent(_ server: ServerConnection, layerURL: URL, where whereClause: String = "1=1",
                       outWkid: Int? = nil) async throws -> Extent {
        var params = ["where": whereClause, "returnExtentOnly": "true"]
        if let outWkid { params["outSR"] = String(outWkid) }
        return try await json(ExtentResponse.self, .post, url: layerURL.appendingPathComponent("query"),
                              params: params, server: server).value.extent
    }
}

/// `query?returnIdsOnly=true`.
public struct ObjectIDsResponse: Decodable, Sendable, Equatable {
    public let objectIdFieldName: String?
    public let objectIds: [Int64]?
}

extension ArcGISClient {
    /// The raw `f=pbf` body of a feature query, for `PBFDecoder`.
    public func featuresPBF(_ server: ServerConnection, layerURL: URL, options: QueryOptions,
                            maxAttempts: Int? = nil) async throws -> Data {
        var params = options.params
        params["f"] = "pbf"
        return try await request(.post, url: layerURL.appendingPathComponent("query"), params: params, server: server,
                                 maxAttempts: maxAttempts)
    }

    /// Every object id matching `where`, as the server lists them.
    public func objectIDs(_ server: ServerConnection, layerURL: URL, where whereClause: String = "1=1") async throws -> [Int64] {
        let params = ["where": whereClause, "returnIdsOnly": "true"]
        return try await json(ObjectIDsResponse.self, .post, url: layerURL.appendingPathComponent("query"),
                              params: params, server: server).value.objectIds ?? []
    }
}
