import Foundation

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
    }

    /// Parses `text`, registers its server root (or touches an existing one), runs a
    /// shallow crawl for a new server, and — when the URL names a service or layer — crawls
    /// that service so the target rows exist. Errors surface verbatim.
    public func open(_ text: String, friendlyName: String? = nil) async throws -> Opened {
        let location = try ArcGISURL.parse(text)
        let existing = try await db.server(rootURL: location.rootURL)
        let server = try await db.addServer(rootURL: location.rootURL,
                                            friendlyName: friendlyName ?? location.rootURL.host ?? "server")
        let isNew = existing == nil
        if isNew {
            try await shallowCrawl(serverID: server.id)
        }
        var service: ServiceRecord?
        var layer: LayerRecord?
        if let serviceURL = location.serviceURL {
            service = try await db.service(serverID: server.id, url: serviceURL)
            if service == nil {
                // Not in the (possibly stale) listing: re-list its folder, then look again.
                try await crawlDirectory(serverID: server.id, folderPath: location.folderPath ?? "")
                service = try await db.service(serverID: server.id, url: serviceURL)
            }
            if let found = service, found.type.hasLayers {
                try await crawlService(serviceID: found.id)
                service = try await db.service(id: found.id)
                if let layerID = location.layerID {
                    layer = try await db.layer(serviceID: found.id, layerID: layerID)
                }
            }
        }
        return Opened(server: try await db.server(id: server.id), location: location,
                      service: service, layer: layer, isNewServer: isNew)
    }

    // MARK: - Shallow crawl

    /// Root listing, then every folder recursively. Records the server's version.
    public func shallowCrawl(serverID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws {
        try await crawlDirectory(serverID: serverID, folderPath: "", recursive: true, progress: progress)
    }

    /// Lists one directory (root when `folderPath` is empty), upserting and pruning its
    /// services. With `recursive`, descends into the folders it lists.
    public func crawlDirectory(serverID: Int64, folderPath: String, recursive: Bool = false,
                               progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws {
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
        guard recursive else { return }
        for folder in listing.folders {
            try Task.checkCancellation()
            // Folder names in a listing are bare at the root but may be "Parent/Child" deeper.
            let path = folder.contains("/") ? folder : (folderPath.isEmpty ? folder : folderPath + "/" + folder)
            try await crawlDirectory(serverID: serverID, folderPath: path, recursive: true, progress: progress)
        }
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
        try await db.updateService(id: serviceID, info: info, raw: raw)
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
                try await db.updateLayer(id: record.id, info: definition, raw: rawLayer)
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
        try await db.updateLayer(id: layerID, info: info, raw: raw)
        progress?(.layer(name: info.name))
    }

    // MARK: - Deep crawl

    /// Re-lists the directory, then crawls every Map/Feature service. Failures of individual
    /// services are reported through `progress` and collected; the crawl continues past them
    /// so one broken service doesn't hide a whole server. Returns the failures.
    @discardableResult
    public func deepCrawl(serverID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlEvent] {
        try await shallowCrawl(serverID: serverID, progress: progress)
        let services = try await db.services(serverID: serverID).filter { $0.type.hasLayers }
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
