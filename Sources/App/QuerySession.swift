import Foundation
import Observation
import ArcGISKit

/// The Query tab's state for one layer: the options, the last result, paging, history.
/// Read-only against the server by construction — it only ever calls `query`.
@MainActor @Observable
final class QuerySession {
    enum SpatialReferenceChoice: Hashable { case native, wgs84 }
    enum Result: Equatable {
        case none
        case count(Int)
        case extent(Extent)
        case grid(QueryGrid, caption: String)
    }

    let layer: LayerRecord
    let service: ServiceRecord
    let fields: [FieldRecord]
    let info: LayerInfo?
    private let client: ArcGISClient
    private let database: AppDatabase
    private let connection: ServerConnection

    // Options
    var whereClause = "1=1"
    /// nil = all fields.
    var outFields: Set<String>? = nil
    var spatialReference: SpatialReferenceChoice = .native
    var orderByField: String? = nil
    var orderAscending = true
    var returnGeometry = true

    // State
    private(set) var result: Result = .none
    private(set) var isRunning = false
    private(set) var error: String?
    private(set) var history: [QueryHistoryRecord] = []
    private var pageOffset = 0
    private(set) var canPageForward = false
    private var lastPageWasPreview = false

    init(layer: LayerRecord, service: ServiceRecord, fields: [FieldRecord], info: LayerInfo?,
         client: ArcGISClient, database: AppDatabase, connection: ServerConnection) {
        self.layer = layer
        self.service = service
        self.fields = fields
        self.info = info
        self.client = client
        self.database = database
        self.connection = connection
    }

    var layerURL: URL { service.url.appendingPathComponent(String(layer.layerID)) }

    /// Page size for previews: the server's ceiling, capped at 500 (SPEC §5.5).
    var pageSize: Int { min(layer.maxRecordCount ?? 1000, 500) }

    // MARK: - Capabilities (each a reason string when unavailable)

    var canDistinct: String? {
        (info?.advancedQueryCapabilities?.supportsDistinct ?? false) ? nil : "The layer does not advertise distinct values"
    }
    var canStatistics: String? {
        layer.supportsStatistics == true ? nil : "The layer does not advertise statistics"
    }
    var canExtent: String? {
        (info?.advancedQueryCapabilities?.supportsReturningQueryExtent ?? true) ? nil : "The layer does not advertise query extents"
    }
    var canOrderBy: String? {
        (layer.supportsOrderBy ?? false) ? nil : "The layer does not advertise ordering"
    }
    var canPaginate: String? {
        layer.supportsPagination == true ? nil : "The layer does not advertise paging; only the first page is available"
    }

    private var outFieldsList: [String]? { outFields.map { list in fields.map(\.name).filter { list.contains($0) } } }
    private var outFieldsText: String { outFieldsList?.joined(separator: ",") ?? "*" }
    private var outWkid: Int? { spatialReference == .wgs84 ? 4326 : nil }
    private var orderBy: (field: String, ascending: Bool)? {
        guard let orderByField, canOrderBy == nil else { return nil }
        return (orderByField, orderAscending)
    }

    // MARK: - Actions

    func count() async {
        await run { [self] in
            let started = Date()
            let n = try await client.count(connection, layerURL: layerURL, where: whereClause)
            try await database.recordQuery(layerID: layer.id, whereClause: whereClause, outFields: outFieldsText,
                                           count: Int64(n), durationMillis: Self.millis(since: started))
            result = .count(n)
            canPageForward = false
        }
    }

    func extent() async {
        await run { [self] in
            let e = try await client.extent(connection, layerURL: layerURL, where: whereClause, outWkid: outWkid)
            result = .extent(e)
            canPageForward = false
        }
    }

    func preview() async {
        pageOffset = 0
        await page()
    }

    func nextPage() async {
        guard canPageForward else { return }
        pageOffset += pageSize
        await page()
    }

    private func page() async {
        await run { [self] in
            let started = Date()
            let options = QueryOptions(whereClause: whereClause, outFields: outFieldsList, returnGeometry: returnGeometry,
                                       outWkid: outWkid, orderBy: orderBy, offset: canPaginate == nil ? pageOffset : nil,
                                       count: pageSize)
            let set = try await client.features(connection, layerURL: layerURL, options: options).value
            let grid = QueryGrid.features(set)
            let first = pageOffset + 1
            let last = pageOffset + set.features.count
            let caption = set.features.isEmpty ? "No features match."
                : "Features \(first.grouped) to \(last.grouped)\(set.exceededTransferLimit ? ", more available" : "")."
            result = .grid(grid, caption: caption)
            canPageForward = set.exceededTransferLimit && canPaginate == nil
            if pageOffset == 0 {
                try await database.recordQuery(layerID: layer.id, whereClause: whereClause, outFields: outFieldsText,
                                               count: nil, durationMillis: Self.millis(since: started))
            }
        }
    }

    func distinct(field: String) async {
        await run { [self] in
            let options = QueryOptions(whereClause: whereClause, outFields: [field], returnGeometry: false,
                                       orderBy: canOrderBy == nil ? (field, true) : nil, distinct: true)
            let set = try await client.features(connection, layerURL: layerURL, options: options).value
            result = .grid(QueryGrid.features(set), caption: "\(set.features.count.grouped) distinct value\(set.features.count == 1 ? "" : "s") of \(field).")
            canPageForward = false
        }
    }

    func statistics() async {
        await run { [self] in
            let definitions = StatisticDefinition.overview(for: fields)
            guard !definitions.isEmpty else {
                result = .grid(QueryGrid(columns: [], rows: []), caption: "No numeric or date fields to summarise.")
                return
            }
            let set = try await client.features(connection, layerURL: layerURL,
                                                options: QueryOptions(whereClause: whereClause, statistics: definitions)).value
            let types = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.esriType) })
            result = .grid(QueryGrid.statistics(set, definitions: definitions, fieldTypes: types),
                           caption: "Min, max, mean, and count for every numeric and date field.")
            canPageForward = false
        }
    }

    func loadHistory() async {
        do { history = try await database.queryHistory(layerID: layer.id) } catch { self.error = String(describing: error) }
    }

    /// Restores a past query's where clause and fields.
    func restore(_ record: QueryHistoryRecord) {
        whereClause = record.whereClause
        if let out = record.outFields, out != "*" {
            outFields = Set(out.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
        } else {
            outFields = nil
        }
    }

    private func run(_ body: @escaping @MainActor () async throws -> Void) async {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        defer { isRunning = false }
        do {
            try await body()
        } catch {
            self.error = String(describing: error)
        }
        await loadHistory()
    }

    private static func millis(since start: Date) -> Int64 {
        Int64((Date().timeIntervalSince(start) * 1000).rounded())
    }
}
