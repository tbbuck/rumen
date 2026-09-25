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
    let client: ArcGISClient
    let db: AppDatabase
    let tokenProvider: @Sendable (ServerRecord) async -> String?

    /// `tokenProvider` supplies a server's token from wherever it is kept (the Keychain in
    /// the app, nothing in tests).
    public init(client: ArcGISClient, database: AppDatabase,
                tokenProvider: @escaping @Sendable (ServerRecord) async -> String? = { _ in nil }) {
        self.client = client
        self.db = database
        self.tokenProvider = tokenProvider
    }

    func connection(_ server: ServerRecord) async -> ServerConnection {
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
    /// `headerOverrides` (origin, referer), `cookie`, `proxyURL` and `insecureTLS` apply to a
    /// new server before its first request.
    public func open(_ text: String, friendlyName: String? = nil,
                     headerOverrides: (origin: String?, referer: String?)? = nil, cookie: String? = nil, proxyURL: String? = nil,
                     insecureTLS: Bool = false,
                     progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> Opened {
        let location: ArcGISLocation
        var kind = ServerKind.arcgis
        do {
            location = try ArcGISURL.parse(text)
        } catch ArcGISURLError.notArcGIS {
            // Outside the rest/services shape (decision 19). A registered root may own it (a
            // proxied directory's service, a lone service's layer, a known OGC endpoint);
            // otherwise the URL is asked what it is before it is taken for an OGC endpoint (M10).
            let servers = try await db.servers()
            if let owned = try ArcGISURL.resolve(text, against: servers) {
                location = owned
            } else if OGCURL.knownEndpoint(of: text, among: servers) != nil {
                return try await openOGC(text, friendlyName: friendlyName, headerOverrides: headerOverrides, cookie: cookie, proxyURL: proxyURL, insecureTLS: insecureTLS, progress: progress)
            } else if let item = PortalURL.parse(text) {
                // A viewer URL: the item lists the services it draws, which for a proxied
                // council map is the only place they are written down.
                return try await openPortalItem(item, headerOverrides: headerOverrides, cookie: cookie,
                                                proxyURL: proxyURL, insecureTLS: insecureTLS, progress: progress)
            } else {
                switch try await probeArcGIS(text, headerOverrides: headerOverrides, cookie: cookie, proxyURL: proxyURL, insecureTLS: insecureTLS) {
                case .found(let finding):
                    location = finding.location
                    kind = finding.kind
                case .refused(let error):
                    throw error
                case .notArcGIS(let reason):
                    do {
                        return try await openOGC(text, friendlyName: friendlyName, headerOverrides: headerOverrides, cookie: cookie, proxyURL: proxyURL, insecureTLS: insecureTLS, progress: progress)
                    } catch OGCError.noServices(let url, let attempts) {
                        throw ArcGISProbeError.nothingAnswered(url: url, arcgis: reason, ogc: attempts)
                    }
                }
            }
        }
        let existing = try await db.server(rootURL: location.rootURL)
        var server = try await db.addServer(rootURL: location.rootURL,
                                            friendlyName: friendlyName ?? location.rootURL.host ?? "server", kind: kind)
        let isNew = existing == nil
        if isNew {
            if let headerOverrides {
                try await db.setHeaderOverrides(serverID: server.id, origin: headerOverrides.origin, referer: headerOverrides.referer)
            }
            if let cookie, !cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await db.setCookie(serverID: server.id, cookie: cookie)
            }
            // Before the shallow crawl, which reads the stored server: a proxy-only server is
            // unreachable until this row says so.
            if let proxyURL, !proxyURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await db.setProxy(serverID: server.id, proxyURL: proxyURL)
            }
            if insecureTLS { try await db.setInsecureTLS(serverID: server.id, insecure: true) }
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
            if service == nil, let servicePath = location.servicePath {
                // Still absent, so no directory here will name it: read it directly. This is
                // the proxied-service case, where every listing above the service is empty.
                service = try await adoptService(serverID: server.id, serviceURL: serviceURL, servicePath: servicePath,
                                                 folderPath: location.folderPath ?? "", progress: progress)
            }
            // A lone service was read in full by the shallow crawl a moment ago; any other is read now.
            if let found = service, found.type.hasLayers {
                if !(isNew && server.kind == .service) {
                    try await crawlService(serviceID: found.id, progress: progress)
                    service = try await db.service(id: found.id)
                }
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
    /// must list; a folder that fails is returned as a problem and the rest carries on. A lone
    /// service is read instead of listed (`crawlLoneService`); an OGC endpoint is probed.
    @discardableResult
    public func shallowCrawl(serverID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlProblem] {
        switch try await db.server(id: serverID).kind {
        case .ogc:
            return try await probeOGC(serverID: serverID, progress: progress)
        case .service:
            try await crawlLoneService(serverID: serverID, progress: progress)
            return []
        case .arcgis:
            return try await crawlDirectory(serverID: serverID, folderPath: "", recursive: true, progress: progress)
        }
    }

    /// The shallow crawl of a `ServerKind.service` server (decision 19): the root is its one
    /// service. The definition is read and classified again (a proxy may have changed what it
    /// fronts), recorded as the only service at the top level, and its layers read as
    /// `crawlService` would, so the tree has them at once.
    public func crawlLoneService(serverID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws {
        let server = try await db.server(id: serverID)
        let conn = await connection(server)
        let (info, raw) = try await client.serviceInfo(conn, serviceURL: server.rootURL)
        guard case .service(let type, _)? = ArcGISProbe.classify(raw) else {
            throw ArcGISProbeError.notAService(url: server.rootURL, found: ArcGISProbe.describe(raw))
        }
        if let version = info.currentVersion {
            try await db.setServerVersion(id: serverID, version: version)
        }
        let service = try await db.upsertService(serverID: serverID, folderPath: "",
                                                 name: ArcGISURL.lastSegment(of: server.rootURL), type: type, url: server.rootURL)
        try await db.pruneServices(serverID: serverID, folderPath: "", keeping: [service.url])
        progress?(.directory(folderPath: "", services: 1))
        try await storeService(service, info: info, raw: raw, connection: conn, progress: progress)
    }

    /// Records a service the directory never listed, by asking the service itself what it is.
    ///
    /// A proxy that fronts named services (ArcGIS Online's `usrsvcs`) enumerates nothing at any
    /// level, so a service reached by its own URL would otherwise never reach the tree: the
    /// listing it should have appeared in came back empty. Named exactly as a listing would
    /// have named it, so a directory that starts answering later reconciles onto the same row.
    @discardableResult
    public func adoptService(serverID: Int64, serviceURL: URL, servicePath: String, folderPath: String,
                             progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> ServiceRecord {
        let server = try await db.server(id: serverID)
        let conn = await connection(server)
        let (info, raw) = try await client.serviceInfo(conn, serviceURL: serviceURL)
        guard case .service(let type, _)? = ArcGISProbe.classify(raw) else {
            throw ArcGISProbeError.notAService(url: serviceURL, found: ArcGISProbe.describe(raw))
        }
        if let version = info.currentVersion {
            try await db.setServerVersion(id: serverID, version: version)
        }
        let service = try await db.upsertService(serverID: serverID, folderPath: folderPath,
                                                 name: servicePath, type: type, url: serviceURL)
        try await storeService(service, info: info, raw: raw, connection: conn, progress: progress)
        return try await db.service(id: service.id)
    }

    /// Lists one directory (root when `folderPath` is empty), upserting and pruning its
    /// services. With `recursive`, descends into the folders it lists.
    @discardableResult
    public func crawlDirectory(serverID: Int64, folderPath: String, recursive: Bool = false,
                               progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlProblem] {
        let server = try await db.server(id: serverID)
        if server.kind == .service {
            // No directory to list: the root is the service, and it has no folders.
            try await crawlLoneService(serverID: serverID, progress: progress)
            return []
        }
        let conn = await connection(server)
        let folderPaths = try await listLevel(serverID: serverID, server: server, conn: conn,
                                              folderPath: folderPath, progress: progress)
        guard recursive else { return [] }
        return try await descend(serverID: serverID, server: server, conn: conn, from: folderPaths, progress: progress)
    }

    /// Lists one folder: its services, its sub-folder rows, and its own "listed" mark. Returns
    /// the sub-folder paths, for the caller to descend into or not.
    private func listLevel(serverID: Int64, server: ServerRecord, conn: ServerConnection, folderPath: String,
                           progress: (@Sendable (CrawlEvent) -> Void)?) async throws -> [String] {
        let (listing, raw) = try await client.serviceDirectory(conn, folder: folderPath.isEmpty ? nil : folderPath)
        // A proxy that fronts named services answers a directory with an empty body: it will
        // not enumerate, which is not the same as having nothing. Reconciling against it would
        // prune the services adopted by name (`adoptService`), so an unlistable folder changes
        // nothing but its own mark.
        if raw.isEmpty {
            try await db.markFolderListed(serverID: serverID, path: folderPath)
            progress?(.directory(folderPath: folderPath, services: 0))
            return []
        }
        if folderPath.isEmpty, let version = listing.currentVersion {
            try await db.setServerVersion(id: serverID, version: version)
        }
        let records = try await db.upsertServices(serverID: serverID, rootURL: server.rootURL,
                                                  folderPath: folderPath, entries: listing.services)
        try await db.pruneServices(serverID: serverID, folderPath: folderPath, keeping: records.map(\.url))
        // Folder names in a listing are bare at the root but may be "Parent/Child" deeper. Every
        // folder listed gets a row now, so one that fails to list below still has a place in
        // the tree, with its error.
        let folderPaths = listing.folders.map { folder in
            folder.contains("/") ? folder : (folderPath.isEmpty ? folder : folderPath + "/" + folder)
        }
        try await db.upsertFolders(serverID: serverID, parentPath: folderPath, paths: folderPaths)
        try await db.pruneFolders(serverID: serverID, parentPath: folderPath, keeping: folderPaths)
        try await db.markFolderListed(serverID: serverID, path: folderPath)
        progress?(.directory(folderPath: folderPath, services: records.count))
        return folderPaths
    }

    /// Walks a folder subtree, a level at a time and several folders at once.
    ///
    /// This was a depth-first recursion that listed one folder, waited, then listed the next, so
    /// a server with a wide or deep tree paid a full round trip per folder in sequence. Breadth
    /// first with an explicit queue keeps the fan-out bounded — a recursive task group would
    /// spawn a task per folder at every level at once — and the width is the host's discovered
    /// limit, so it widens as the server copes.
    ///
    /// A folder that will not list is recorded on its row and collected, and the walk carries on:
    /// one broken folder must not hide the rest of the server.
    private func descend(serverID: Int64, server: ServerRecord, conn: ServerConnection, from roots: [String],
                         progress: (@Sendable (CrawlEvent) -> Void)?) async throws -> [CrawlProblem] {
        let host = ArcGISURL.origin(of: server.rootURL)
        var queue = roots
        var problems = [CrawlProblem]()
        while !queue.isEmpty {
            try Task.checkCancellation()
            var nextLevel = [String]()
            try await withThrowingTaskGroup(of: ([String], CrawlProblem?).self) { group in
                var pending = queue[...]
                var inFlight = 0
                // `fill` stays synchronous and takes the width: an async local function that
                // captures the group counts as sending it across an isolation boundary, which
                // Swift 6 rejects. The width is still re-read before every refill.
                func fill(width: Int) {
                    while inFlight < width, let path = pending.popFirst() {
                        group.addTask { [self] in
                            do {
                                let children = try await listLevel(serverID: serverID, server: server, conn: conn,
                                                                   folderPath: path, progress: progress)
                                return (children, nil)
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch let error as ArcGISClientError where error == .cancelled {
                                throw CancellationError()
                            } catch {
                                let message = String(describing: error)
                                try await db.markFolderFailed(serverID: serverID, path: path, error: message)
                                progress?(.failed(what: "folder \(path)", error: message))
                                return ([], CrawlProblem(folderPath: path, message: message))
                            }
                        }
                        inFlight += 1
                    }
                }
                fill(width: max(1, await client.concurrencyLimit(forHost: host)))
                while inFlight > 0 {
                    guard let outcome = try await group.next() else { break }
                    inFlight -= 1
                    nextLevel += outcome.0
                    if let problem = outcome.1 { problems.append(problem) }
                    try Task.checkCancellation()
                    fill(width: max(1, await client.concurrencyLimit(forHost: host)))
                }
            }
            queue = nextLevel
        }
        return problems
    }

    /// Lists one folder and everything under it, recording the outcome on the folder's row:
    /// the shallow crawl's per-folder step and the folder page's Retry. A failure is written
    /// to the row, then rethrown.
    @discardableResult
    public func crawlFolder(serverID: Int64, path: String,
                            progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlProblem] {
        do {
            return try await crawlDirectory(serverID: serverID, folderPath: path, recursive: true, progress: progress)
        } catch {
            if error is CancellationError { throw error }
            if let client = error as? ArcGISClientError, case .cancelled = client { throw error }
            try await db.markFolderFailed(serverID: serverID, path: path, error: String(describing: error))
            throw error
        }
    }

    // MARK: - Service crawl

    /// Fetches a service's definition and every layer/table definition beneath it. Uses the
    /// bulk `layers` endpoint (one request) and falls back to per-layer requests when the
    /// bulk endpoint is missing, errors, or omits a layer.
    public func crawlService(serviceID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws {
        let service = try await db.service(id: serviceID)
        if service.type.isOGC { return try await crawlOGCService(serviceID: serviceID, progress: progress) }
        let server = try await db.server(id: service.serverID)
        let conn = await connection(server)
        let (info, raw) = try await client.serviceInfo(conn, serviceURL: service.url)
        try await storeService(service, info: info, raw: raw, connection: conn, progress: progress)
    }

    /// Records a fetched service definition and reads every layer and table beneath it: the
    /// bulk `layers` endpoint (one request), falling back to per-layer requests when it is
    /// missing, errors, or omits a layer.
    func storeService(_ service: ServiceRecord, info: ServiceInfo, raw: Data, connection conn: ServerConnection,
                      progress: (@Sendable (CrawlEvent) -> Void)?) async throws {
        let serviceID = service.id
        let serviceBox = try await db.wgs84Extent(of: info.fullExtent, wkid: info.spatialReference?.effectiveWkid)
        try await db.updateService(id: serviceID, info: info, raw: raw, extentWGS84: serviceBox)
        let summaries = try await db.upsertLayers(serviceID: serviceID, layers: info.layers, tables: info.tables)
        try await db.pruneLayers(serviceID: serviceID, keeping: summaries.map(\.layerID))
        progress?(.service(name: service.name, layers: summaries.count))
        guard !summaries.isEmpty else { return }

        var stored = Set<Int>()
        // The bulk endpoint is a genuine best-effort: plenty of servers do not have it, and the
        // per-layer fallback below covers every case it misses. What must not be swallowed is a
        // cancellation — a `try?` here turned "the user stopped the crawl" into "no bulk answer"
        // and went on to make a request per layer.
        var bulk: (value: LayersResponse, raw: Data)?
        do {
            bulk = try await client.layers(conn, serviceURL: service.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArcGISClientError where error == .cancelled {
            throw CancellationError()
        } catch {
            bulk = nil
        }
        if let bulk {
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
        // The per-layer fallback, for a service whose bulk `layers` endpoint is missing or
        // incomplete. This used to be strictly sequential, so a MapServer with a hundred layers
        // — the shape most likely to lack the bulk endpoint in the first place, since it is the
        // older servers that do — cost a hundred round trips end to end. They go out together
        // now, bounded by what the host has shown it can take rather than by a number here.
        let remaining = summaries.filter { !stored.contains($0.layerID) }
        guard !remaining.isEmpty else { return }
        let host = ArcGISURL.origin(of: service.url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            var pending = remaining[...]
            var inFlight = 0
            func fill(width: Int) {
                while inFlight < width, let record = pending.popFirst() {
                    group.addTask { [self] in
                        try await crawlLayer(layerID: record.id, connection: conn, serviceURL: service.url,
                                             progress: progress)
                    }
                    inFlight += 1
                }
            }
            fill(width: max(1, await client.concurrencyLimit(forHost: host)))
            while inFlight > 0 {
                _ = try await group.next()
                inFlight -= 1
                try Task.checkCancellation()
                fill(width: max(1, await client.concurrencyLimit(forHost: host)))
            }
        }
    }

    /// Fetches one layer's definition.
    public func crawlLayer(layerID: Int64, progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws {
        let layer = try await db.layer(id: layerID)
        let service = try await db.service(id: layer.serviceID)
        // An OGC layer has no definition of its own beyond the capabilities: refresh the service.
        if service.type.isOGC { return try await crawlOGCService(serviceID: service.id, progress: progress) }
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

    /// Re-lists the directory, then crawls every Map/Feature service, `concurrency` at a time
    /// (the client's per-host cap still bounds the requests in flight). Failures of individual
    /// services are reported through `progress` and collected; the crawl continues past them
    /// so one broken service doesn't hide a whole server. Returns the failures.
    /// Services crawled within `skipFresh` are skipped, so re-running after a cancel resumes
    /// where it stopped rather than starting over.
    @discardableResult
    public func deepCrawl(serverID: Int64, skipFresh: TimeInterval = 3600,
                          progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> [CrawlEvent] {
        try await shallowCrawl(serverID: serverID, progress: progress)
        let server = try await db.server(id: serverID)
        let host = ArcGISURL.origin(of: server.rootURL)
        let cutoff = Date().addingTimeInterval(-skipFresh)
        let services = try await db.services(serverID: serverID).filter { service in
            service.type.hasLayers && (service.fetchedAt.map { $0 < cutoff } ?? true)
        }
        // What this used to declare as a fixed 4 is now the host's own discovered limit, read
        // afresh on every refill so a crawl of 3,900 services widens as the server proves it can
        // cope and narrows the moment it cannot.
        if let remembered = try await db.serverConcurrency(serverID: serverID) {
            await client.seedConcurrency(remembered, forHost: host)
        }
        var failures = [CrawlEvent]()
        try await withThrowingTaskGroup(of: CrawlEvent?.self) { group in
            var pending = services[...]
            var inFlight = 0
            func enqueue(_ service: ServiceRecord) {
                group.addTask { [self] in
                    do {
                        try await self.crawlService(serviceID: service.id, progress: progress)
                        return nil
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as ArcGISClientError where error == .cancelled {
                        throw CancellationError()
                    } catch {
                        let event = CrawlEvent.failed(what: service.name, error: String(describing: error))
                        progress?(event)
                        return event
                    }
                }
                inFlight += 1
            }
            func fill(width: Int) {
                while inFlight < width, let next = pending.popFirst() { enqueue(next) }
            }
            fill(width: max(1, await client.concurrencyLimit(forHost: host)))
            while inFlight > 0 {
                guard let outcome = try await group.next() else { break }
                inFlight -= 1
                if let failure = outcome { failures.append(failure) }
                try Task.checkCancellation()
                fill(width: max(1, await client.concurrencyLimit(forHost: host)))
            }
        }
        try await db.markDeepCrawl(serverID: serverID)
        // A crawl is the longest conversation this app has with a server, so it is the best
        // evidence of what the host will take. It has nothing to say about a page size.
        try? await db.recordServerConcurrency(await client.concurrencyLimit(forHost: host), serverID: serverID)
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
        let assessment: Assessment
        if service.type.isOGC {
            let twin = try await ogcTwin(of: layer, in: service)
            assessment = Extractability.assessOGC(layer: layer, service: service, twin: twin?.0, twinService: twin?.1)
        } else {
            let twin = try await twin(of: layer, in: service)
            assessment = Extractability.assess(layer: layer, service: service, twin: twin?.0, twinService: twin?.1)
        }
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
        if service.type.isOGC { return try await probeOGCCount(layer: source, service: service, server: server) }
        let url = service.url.appendingPathComponent(String(source.layerID))
        do {
            let count = Int64(try await client.count(await connection(server), layerURL: url))
            try await db.setFeatureCount(layerID: layerID, count: count)
            if assessment.viaTwin { try await db.setFeatureCount(layerID: source.id, count: count) }
            return count
        } catch let error as ArcGISClientError {
            if case .server(_, let message, _, _, _) = error {
                try await db.setExtractability(layerID: layerID, extractable: false,
                                               reason: "The server refused the count probe: \(message)",
                                               transport: nil, siblingLayerID: nil)
            }
            throw error
        }
    }
}

// MARK: - Portal items

extension Crawler {

    /// The services a portal item names, following an app to the web map it draws.
    ///
    /// One hop only: app → web map → its layers. A web map is where layer URLs actually live,
    /// and an app that points at another app is not a shape worth chasing.
    public func resolvePortalItem(_ ref: PortalItemRef, proxyURL: String? = nil, insecureTLS: Bool = false) async throws -> [PortalService] {
        let connection = ServerConnection(rootURL: ref.portal, proxyURL: proxyURL, insecureTLS: insecureTLS)
        let info = try await client.json(PortalItemInfo.self, url: ref.itemURL, server: connection).value

        // A service item is its own answer.
        if let text = info.url, let url = URL(string: text), ArcGISURL.looksLikeService(url) {
            return [PortalService(title: info.title ?? url.lastPathComponent, url: url)]
        }

        let data = try await client.json(PortalItemData.self, url: ref.dataURL, server: connection).value
        let direct = data.serviceURLs
        if !direct.isEmpty { return direct }

        if let mapID = data.referencedMapID {
            let map = PortalItemRef(portal: ref.portal, itemID: mapID)
            let layers = try await client.json(PortalItemData.self, url: map.dataURL, server: connection).value.serviceURLs
            if !layers.isEmpty { return layers }
        }
        throw PortalItemError.noServices(itemID: ref.itemID, type: info.type)
    }

    /// Opens every service a portal item names. The first is returned as the one to land on;
    /// the rest are registered and crawled so the tree has them, because a viewer's value is
    /// precisely that it lists services no directory will.
    ///
    /// One service failing does not sink the others: its message is carried back as a problem
    /// against the item, and the ones that opened still open.
    public func openPortalItem(_ ref: PortalItemRef, headerOverrides: (origin: String?, referer: String?)? = nil,
                               cookie: String? = nil, proxyURL: String? = nil, insecureTLS: Bool = false,
                               progress: (@Sendable (CrawlEvent) -> Void)? = nil) async throws -> Opened {
        let services = try await resolvePortalItem(ref, proxyURL: proxyURL, insecureTLS: insecureTLS)
        var first: Opened?
        var problems = [CrawlProblem]()
        for service in services {
            do {
                let opened = try await open(service.url.absoluteString, friendlyName: service.title,
                                            headerOverrides: headerOverrides, cookie: cookie, proxyURL: proxyURL, insecureTLS: insecureTLS,
                                            progress: progress)
                if first == nil { first = opened }
                problems += opened.problems
            } catch {
                let message = String(describing: error)
                progress?(.failed(what: service.title, error: message))
                problems.append(CrawlProblem(folderPath: service.title, message: message))
            }
        }
        guard var opened = first else {
            throw PortalItemError.noServices(itemID: ref.itemID, type: nil)
        }
        opened.problems = problems
        return opened
    }
}
