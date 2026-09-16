import Foundation

/// A folder that could not be listed during a shallow crawl; the rest of the server still opens.
public struct CrawlProblem: Sendable, Equatable {
    public let folderPath: String
    public let message: String
    public init(folderPath: String, message: String) {
        self.folderPath = folderPath
        self.message = message
    }
}

/// Progress events from a crawl, for a UI progress indicator.
public enum CrawlEvent: Sendable, Equatable {
    case directory(folderPath: String, services: Int)
    case service(name: String, layers: Int)
    case layer(name: String)
    case failed(what: String, error: String)
}

/// Fetches metadata through the client and persists it through the store (SPEC §5.2).
///
/// Three depths: **shallow** (root + folders + service lists) on add, **service** (one
/// service's definition + all its layer definitions) on select, and **deep** (every
/// layer-bearing service under a server) on demand. Cache reads never hit the network;
/// only these entry points do.
public actor Crawler {
    private let client: ArcGISClient
    private let db: AppDatabase
    private let tokenProvider: @Sendable (ServerRecord) async -> String?

    /// `tokenProvider` supplies a server's token from wherever it is kept (the Keychain in
    /// the app, nothing in tests).
    public init(client: ArcGISClient, database: AppDatabase,
                tokenProvider: @escaping @Sendable (ServerRecord) async -> String? = { _ in nil }) {
        self.client = client
        self.db = database
        self.tokenProvider = tokenProvider
    }

    private func connection(_ server: ServerRecord) async -> ServerConnection {
        server.connection(token: await tokenProvider(server))
    }

    // MARK: - Add / open

    /// The result of opening a pasted URL: the (possibly pre-existing) server, and the
    /// service / layer rows the URL pointed at, if any.
    public struct Opened: Sendable, Equatable {
        public let server: ServerRecord
        public let location: ArcGISLocation
        public let service: ServiceRecord?
        public let layer: LayerRecord?
        public let isNewServer: Bool
        /// Folders that could not be listed; empty when the whole directory was read.
        public var problems: [CrawlProblem] = []
    }

    /// Parses `text`, registers its server root (or touches an existing one), runs a
    /// shallow crawl for a new server, and — when the URL names a service or layer — crawls
    /// that service so the target rows exist. Errors surface verbatim.
    /// `headerOverrides` (origin, referer) and `cookie` apply to a new server before its first
    /// request.
    public func open(_ text: String, friendlyName: String? = nil,
                     headerOverrides: (origin: String?, referer: String?)? = nil, cookie: String? = nil,
                     progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> Opened {
        let location = try ArcGISURL.parse(text)
        let existing = try await db.server(rootURL: location.rootURL)
        var server = try await db.addServer(rootURL: location.rootURL,
                                            friendlyName: friendlyName ?? location.rootURL.host ?? "server")
        let isNew = existing == nil
        if isNew {
            if let headerOverrides {
                try await db.setHeaderOverrides(serverID: server.id, origin: headerOverrides.origin, referer: headerOverrides.referer)
            }
            if let cookie, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await db.setCookie(serverID: server.id, cookie: cookie)
            }
            server = try await db.server(id: server.id)
        }
        var problems = [CrawlProblem]()
        if isNew {
            problems = try await shallowCrawl(serverID: server.id, progress: progress)
        }
        var service: ServiceRecord?
        var layer: LayerRecord?
        if let serviceURL = location.serviceURL {
            service = try await db.service(serverID: server.id, url: serviceURL)
            if service == nil {
                // Not in the (possibly stale) listing: re-list its folder, then look again.
                try await crawlDirectory(serverID: server.id, folderPath: location.folderPath ?? "", progress: progress)
                service = try await db.service(serverID: server.id, url: serviceURL)
            }
            if let found = service, found.type.hasLayers {
                try await crawlService(serviceID: found.id, progress: progress)
                service = try await db.service(id: found.id)
                if let layerID = location.layerID {
                    layer = try await db.layer(serviceID: found.id, layerID: layerID)
                }
            }
        }
        var opened = Opened(server: try await db.server(id: server.id), location: location,
                            service: service, layer: layer, isNewServer: isNew)
        opened.problems = problems
        return opened
    }

    // MARK: - Shallow crawl

    /// Root listing, then every folder recursively. Records the server's version. The root
    /// must list; a folder that fails is returned as a problem and the rest carries on.
    @discardableResult
    public func shallowCrawl(serverID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlProblem] {
        try await crawlDirectory(serverID: serverID, folderPath: "", recursive: true, progress: progress)
    }

    /// Lists one directory (root when `folderPath` is empty), upserting and pruning its
    /// services. With `recursive`, descends into the folders it lists.
    @discardableResult
    public func crawlDirectory(serverID: Int64, folderPath: String, recursive: Bool = false,
                               progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlProblem] {
        let server = try await db.server(id: serverID)
        let conn = await connection(server)
        let listing = try await client.serviceDirectory(conn, folder: folderPath.isEmpty ? nil : folderPath).value
        if folderPath.isEmpty, let version = listing.currentVersion {
            try await db.setServerVersion(id: serverID, version: version)
        }
        let records = try await db.upsertServices(serverID: serverID, rootURL: server.rootURL,
                                                  folderPath: folderPath, entries: listing.services)
        try await db.pruneServices(serverID: serverID, folderPath: folderPath, keeping: records.map(\.url))
        progress?(.directory(folderPath: folderPath, services: records.count))
        guard recursive else { return [] }
        var problems = [CrawlProblem]()
        for folder in listing.folders {
            try Task.checkCancellation()
            // Folder names in a listing are bare at the root but may be "Parent/Child" deeper.
            let path = folder.contains("/") ? folder : (folderPath.isEmpty ? folder : folderPath + "/" + folder)
            do {
                problems += try await crawlDirectory(serverID: serverID, folderPath: path, recursive: true, progress: progress)
            } catch {
                if error is CancellationError { throw error }
                if let client = error as? ArcGISClientError, case .cancelled = client { throw error }
                let message = String(describing: error)
                progress?(.failed(what: "folder \(path)", error: message))
                problems.append(CrawlProblem(folderPath: path, message: message))
            }
        }
        return problems
    }

    // MARK: - Service crawl

    /// Fetches a service's definition and every layer/table definition beneath it. Uses the
    /// bulk `layers` endpoint (one request) and falls back to per-layer requests when the
    /// bulk endpoint is missing, errors, or omits a layer.
    public func crawlService(serviceID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws {
        let service = try await db.service(id: serviceID)
        let server = try await db.server(id: service.serverID)
        let conn = await connection(server)

        let (info, raw) = try await client.serviceInfo(conn, serviceURL: service.url)
        let serviceBox = try await db.wgs84Extent(of: info.fullExtent, wkid: info.spatialReference?.effectiveWkid)
        try await db.updateService(id: serviceID, info: info, raw: raw, extentWGS84: serviceBox)
        let summaries = try await db.upsertLayers(serviceID: serviceID, layers: info.layers, tables: info.tables)
        try await db.pruneLayers(serviceID: serviceID, keeping: summaries.map(\.layerID))
        progress?(.service(name: service.name, layers: summaries.count))
        guard !summaries.isEmpty else { return }

        var stored = Set<Int>()
        if let bulk = try? await client.layers(conn, serviceURL: service.url) {
            // The bulk response has no per-layer raw JSON of its own; re-encode each element
            // so the stored raw is exactly that layer's definition.
            for definition in bulk.value.layers + bulk.value.tables {
                guard let record = summaries.first(where: { $0.layerID == definition.id }) else { continue }
                let rawLayer = try Self.rawElement(for: definition.id, in: bulk.raw) ?? Data()
                try await db.updateLayer(id: record.id, info: definition, raw: rawLayer,
                                         extentWGS84: try await wgs84(definition))
                stored.insert(definition.id)
                progress?(.layer(name: definition.name))
            }
        }
        for record in summaries where !stored.contains(record.layerID) {
            try Task.checkCancellation()
            try await crawlLayer(layerID: record.id, connection: conn, serviceURL: service.url, progress: progress)
        }
    }

    /// Fetches one layer's definition.
    public func crawlLayer(layerID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws {
        let layer = try await db.layer(id: layerID)
        let service = try await db.service(id: layer.serviceID)
        let server = try await db.server(id: service.serverID)
        try await crawlLayer(layerID: layerID, connection: await connection(server), serviceURL: service.url,
                             progress: progress)
    }

    private func crawlLayer(layerID: Int64, connection: ServerConnection, serviceURL: URL,
                            progress: (@Sendable (CrawlEvent) -> Void)?) async throws {
        let layer = try await db.layer(id: layerID)
        let url = serviceURL.appendingPathComponent(String(layer.layerID))
        let (info, raw) = try await client.layerInfo(connection, layerURL: url)
        try await db.updateLayer(id: layerID, info: info, raw: raw, extentWGS84: try await wgs84(info))
        progress?(.layer(name: info.name))
    }

    // MARK: - Deep crawl

    /// Re-lists the directory, then crawls every Map/Feature service. Failures of individual
    /// services are reported through `progress` and collected; the crawl continues past them
    /// so one broken service doesn't hide a whole server. Returns the failures.
    /// Services crawled within `skipFresh` are skipped, so re-running after a cancel resumes
    /// where it stopped rather than starting over.
    @discardableResult
    public func deepCrawl(serverID: Int64, skipFresh: TimeInterval = 3600,
                          progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlEvent] {
        try await shallowCrawl(serverID: serverID, progress: progress)
        let cutoff = Date().addingTimeInterval(-skipFresh)
        let services = try await db.services(serverID: serverID).filter { service in
            service.type.hasLayers && (service.fetchedAt.map { $0 < cutoff } ?? true)
        }
        var failures = [CrawlEvent]()
        for service in services {
            try Task.checkCancellation()
            do {
                try await crawlService(serviceID: service.id, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let event = CrawlEvent.failed(what: service.name, error: String(describing: error))
                failures.append(event)
                progress?(event)
            }
        }
        try await db.markDeepCrawl(serverID: serverID)
        return failures
    }

    /// The WGS 84 box for a layer definition (nil when empty or the SR is unknown to PROJ).
    /// Requires `AppDatabase.loadSpatial()` to have run; the app does that at launch.
    private func wgs84(_ info: LayerInfo) async throws -> BoundingBox? {
        try await db.wgs84Extent(of: info.extent, wkid: info.spatialReference?.effectiveWkid)
    }

    // MARK: - Raw JSON slicing

    /// Extracts the JSON object for layer `id` from a bulk `layers` response by decoding it
    /// into generic values and re-encoding just that element. Nil if absent.
    public static func rawElement(for id: Int, in bulk: Data) throws -> Data? {
        struct Envelope: Decodable { let layers: [JSONValue]?; let tables: [JSONValue]? }
        let envelope = try JSONDecoder().decode(Envelope.self, from: bulk)
        for element in (envelope.layers ?? []) + (envelope.tables ?? []) where element["id"]?.intValue == id {
            return try JSONEncoder().encode(element)
        }
        return nil
    }
}

// MARK: - Extractability

extension Crawler {
    /// The FeatureServer twin of a MapServer layer: the same service name with type
    /// FeatureServer in the same directory, and the layer with the same id under it. Crawls
    /// the twin service if it is listed but not yet crawled (one or two requests, once).
    public func twin(of layer: LayerRecord, in service: ServiceRecord) async throws -> (LayerRecord, ServiceRecord)? {
        guard service.type == .mapServer else { return nil }
        let twinURL = service.url.deletingLastPathComponent().appendingPathComponent(ServiceType.featureServer.name)
        guard var twinService = try await db.service(serverID: service.serverID, url: twinURL) else { return nil }
        if !twinService.isCrawled {
            try await crawlService(serviceID: twinService.id)
            twinService = try await db.service(id: twinService.id)
        }
        guard let twinLayer = try await db.layer(serviceID: twinService.id, layerID: layer.layerID) else { return nil }
        return (twinLayer, twinService)
    }

    /// Assesses a layer from cached metadata (finding its twin first), persists the verdict,
    /// and returns it. No count probe; see `probeCount`.
    public func assess(layerID: Int64) async throws -> Assessment {
        let layer = try await db.layer(id: layerID)
        let service = try await db.service(id: layer.serviceID)
        let twin = try await twin(of: layer, in: service)
        let assessment = Extractability.assess(layer: layer, service: service, twin: twin?.0, twinService: twin?.1)
        try await db.setExtractability(layerID: layerID, extractable: assessment.verdict, reason: assessment.reason,
                                       transport: assessment.transport?.rawValue,
                                       siblingLayerID: assessment.viaTwin ? assessment.sourceLayerID : nil)
        return assessment
    }

    /// `returnCountOnly` against the layer the assessment would download from. A count
    /// confirms extractability and is stored; a server error overturns it, with the server's
    /// message as the reason. Returns the count.
    @discardableResult
    public func probeCount(layerID: Int64) async throws -> Int64 {
        let assessment = try await assess(layerID: layerID)
        let source = try await db.layer(id: assessment.sourceLayerID)
        let service = try await db.service(id: source.serviceID)
        let server = try await db.server(id: service.serverID)
        let url = service.url.appendingPathComponent(String(source.layerID))
        do {
            let count = Int64(try await client.count(await connection(server), layerURL: url))
            try await db.setFeatureCount(layerID: layerID, count: count)
            if assessment.viaTwin { try await db.setFeatureCount(layerID: source.id, count: count) }
            return count
        } catch let error as ArcGISClientError {
            if case .server(_, let message, _, _) = error {
                try await db.setExtractability(layerID: layerID, extractable: false,
                                               reason: "The server refused the count probe: \(message)",
                                               transport: nil, siblingLayerID: nil)
            }
            throw error
        }
    }
}
