import Foundation
import SwiftUI
import AppKit
import Observation
import ArcGISKit
import SQLiteKit

/// One visible tree row: a node plus its indent. Indents follow DESIGN-TOKENS: folders and
/// root services at 14, +18 per folder level, layers a further 20 in.
struct TreeRowItem: Identifiable, Equatable {
    let node: TreeNode
    let indent: CGFloat
    var id: NodeID { node.id }
}

enum LayerTab: String, CaseIterable, Identifiable {
    case overview = "Overview", fields = "Fields", query = "Query", download = "Download", map = "Map", raw = "Raw"
    var id: String { rawValue }
}

/// A pasted URL whose server is not known yet, awaiting the Add-server sheet.
struct PendingAdd: Identifiable, Equatable {
    let text: String
    let location: ArcGISLocation
    var id: String { text }
}

/// Single source of truth for the window: known servers, the current server's tree, the
/// selection, the page it drives, the path bar, and the sheets. Main-actor bound; all
/// engine and network work happens on the `AppDatabase`, `ArcGISClient`, and `Crawler` actors.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable { case opening, ready, failed(String) }

    // Engine
    private(set) var phase: Phase = .opening
    private(set) var database: AppDatabase?
    private let client = ArcGISClient()
    private var crawler: Crawler?
    private var engine: DownloadEngine?

    // Servers + tree
    private(set) var servers: [ServerRecord] = []
    private(set) var currentServer: ServerRecord?
    private(set) var services: [ServiceRecord] = []
    private(set) var layersByService: [Int64: [LayerRecord]] = [:]
    private(set) var tree: TreeNode?
    private(set) var selection: NodeID?
    private(set) var expanded: Set<NodeID> = []
    private(set) var loadingNodes: Set<NodeID> = []
    private(set) var nodeErrors: [NodeID: String] = [:]

    // Page
    private(set) var currentService: ServiceRecord?
    private(set) var currentLayer: LayerRecord?
    private(set) var currentFields: [FieldRecord] = []
    private(set) var currentRawJSON: String?
    private(set) var pathContent: PathBarContent?
    private(set) var assessment: Assessment?
    private(set) var currentLayerInfo: LayerInfo?
    private(set) var querySession: QuerySession?
    private(set) var mapSession: MapSession?
    private(set) var probing = false
    private(set) var isAssessing = false
    private(set) var probeError: String?
    private var deepCrawlTask: Task<Void, Never>?
    var layerTab: LayerTab = .overview

    // Chrome
    var isEditingURL = false
    var urlDraft = ""
    var pendingAdd: PendingAdd?
    var settingsServer: ServerRecord?
    var showRecents = false
    var columnSearch = ""
    var search = FieldSearchOptions(text: "")
    var searchAllServers = false
    private(set) var searchHits: [FieldSearchHit] = []
    private(set) var searchUncrawled = 0
    private(set) var searchError: String?
    var focusColumnSearch = false
    var treeFilter = ""
    var appearanceOverride: ColorScheme?
    private(set) var errorText: String?
    private(set) var deepCrawlStatus: String?
    /// While a server is being opened: where, and what the crawler is doing right now.
    private(set) var openingStatus: OpeningStatus?
    /// Cached service counts per server, for the start page.
    private(set) var serverServiceCounts: [Int64: Int] = [:]
    private var treeVersion = 0
    @ObservationIgnored private var filterCache: (needle: String, version: Int, rows: [TreeRowItem], overflow: Int)?

    // Transfers
    var showTransfers = false
    private(set) var runs: [TransferRun] = []
    private(set) var transfersError: String?
    private(set) var downloadDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ArcGIS Explorer", isDirectory: true)
    private var liveProgress: [Int64: DownloadProgress] = [:]
    private var liveChunks: [Int64: [ChunkStatus]] = [:]
    private var runStarted: [Int64: Date] = [:]
    var pendingOverwrite: DownloadRequest?

    // MARK: - Startup

    /// Opens the app database, migrates it, loads `spatial` for extents, and shows the most
    /// recently visited server. Any failure is surfaced verbatim; there is nothing sensible to
    /// do with a broken app database but say so.
    func start() async {
        do {
            let db = try AppDatabase(path: AppDatabase.defaultURL().path)
            try await db.migrate()
            try await db.loadSpatial()
            database = db
            let crawler = Crawler(client: client, database: db)
            self.crawler = crawler
            engine = DownloadEngine(client: client, database: db, crawler: crawler,
                                    stagingDirectory: AppDatabase.defaultURL().deletingLastPathComponent().appendingPathComponent("staging"))
            if let dir = try await db.setting("download_dir") { downloadDirectory = URL(fileURLWithPath: dir) }
            switch try await db.setting("appearance") {
            case "light": appearanceOverride = .light
            case "dark": appearanceOverride = .dark
            default: appearanceOverride = nil
            }
            try await db.markInterruptedDownloads()
            try await reloadServers()
            await reloadRuns()
            // Land on the start page: the user picks a server rather than being dropped into one.
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func reloadServers() async throws {
        guard let database else { return }
        servers = try await database.servers()
        if let current = currentServer { currentServer = servers.first { $0.id == current.id } }
        var counts = [Int64: Int]()
        for server in servers { counts[server.id] = try await database.services(serverID: server.id).count }
        serverServiceCounts = counts
    }

    /// Back to the start page: no server, no tree, no selection.
    func showStartPage() {
        currentServer = nil
        tree = nil
        expanded = []
        selection = nil
        pathContent = nil
        clearPage()
    }

    /// The start page's URL field: same path as the bar.
    func openText(_ text: String) async {
        urlDraft = text
        await submitURL()
    }

    // MARK: - Tree

    /// Loads a server's cached services and layers and rebuilds its tree. Never touches the
    /// network.
    func selectServer(_ id: Int64) async {
        guard let database else { return }
        do {
            let server = try await database.server(id: id)
            currentServer = server
            try await reloadTree()
            if expanded.isEmpty { expanded = [.server(id)] }
            await select(.server(id))
        } catch {
            errorText = String(describing: error)
        }
    }

    private func reloadTree() async throws {
        guard let database, let server = currentServer else { tree = nil; return }
        services = try await database.services(serverID: server.id)
        var byService = [Int64: [LayerRecord]]()
        for service in services where service.type.hasLayers && service.isCrawled {
            byService[service.id] = try await database.layers(serviceID: service.id)
        }
        layersByService = byService
        tree = TreeBuilder.build(server: server, services: services, layersByService: byService)
        treeVersion += 1
    }

    /// The flattened, currently visible rows (server header is drawn separately).
    var visibleRows: [TreeRowItem] {
        guard let tree else { return [] }
        var rows = [TreeRowItem]()
        func walk(_ nodes: [TreeNode]) {
            for node in nodes {
                rows.append(TreeRowItem(node: node, indent: Self.indent(for: node)))
                if expanded.contains(node.id) { walk(node.children) }
            }
        }
        walk(tree.children)
        return rows
    }

    private static func indent(for node: TreeNode) -> CGFloat {
        switch node.kind {
        case .server: return 0
        case .folder, .service: return 14 + 18 * CGFloat(node.folderDepth)
        case .layer, .table: return 14 + 18 * CGFloat(node.folderDepth) + 20
        }
    }

    func isExpanded(_ id: NodeID) -> Bool { expanded.contains(id) }

    /// Expands or collapses a node. Expanding an uncrawled service crawls it first.
    func toggleExpanded(_ node: TreeNode) async {
        if expanded.contains(node.id) {
            expanded.remove(node.id)
            return
        }
        expanded.insert(node.id)
        if case .service(let serviceID) = node.id, node.children.isEmpty, node.isExpandable {
            await crawlService(serviceID)
        }
    }

    // MARK: - Selection and pages

    /// Selects a node and loads what its page needs. Selecting an uncrawled service crawls it.
    func select(_ id: NodeID?) async {
        selection = id
        guard let id, let database, let server = currentServer else { clearPage(); pathContent = nil; return }
        do {
            switch id {
            case .server:
                clearPage()
                pathContent = PathBarContent.build(server: server)
            case .folder(_, let path):
                clearPage()
                pathContent = PathBarContent.build(server: server, folderPath: path)
            case .service(let serviceID):
                let service = try await database.service(id: serviceID)
                guard selection == id else { return }
                clearPage()
                currentService = service
                pathContent = PathBarContent.build(server: server, service: service)
                if !service.isCrawled && service.type.hasLayers {
                    await crawlService(serviceID)
                    guard selection == id else { return }
                    currentService = try await database.service(id: serviceID)
                }
            case .layer(let layerID):
                // Load everything first, then swap the page in one go: no blank frame in between.
                let layer = try await database.layer(id: layerID)
                let service = try await database.service(id: layer.serviceID)
                let fields = try await database.fields(layerID: layerID)
                var info: LayerInfo?
                if let raw = try await database.layerRawJSON(id: layerID), let data = raw.data(using: .utf8) {
                    info = try? ArcGISJSON.decode(LayerInfo.self, from: data)
                }
                guard selection == id else { return }   // the user moved on while we loaded
                clearPage()
                currentService = service
                currentLayer = layer
                currentFields = fields
                currentLayerInfo = info
                pathContent = PathBarContent.build(server: server, service: service, layer: layer)
                querySession = QuerySession(layer: layer, service: service, fields: fields, info: info,
                                            client: client, database: database, connection: server.connection())
                mapSession = MapSession(layer: layer, service: service, client: client, database: database,
                                        connection: server.connection(),
                                        storedRuns: runs.filter { $0.record.layerID == layer.id && $0.status == .complete }.map(\.record),
                                        querySet: nil, queryWkid: nil)
                await assessCurrentLayer()
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    private func clearPage() {
        currentService = nil
        currentLayer = nil
        currentFields = []
        currentRawJSON = nil
        assessment = nil
        probeError = nil
        currentLayerInfo = nil
        querySession = nil
        mapSession = nil
    }

    /// Loads the pretty-printed raw JSON for the Raw tab on demand.
    func loadRawJSON() async {
        guard let database, let layer = currentLayer, currentRawJSON == nil else { return }
        do {
            let raw = try await database.layerRawJSON(id: layer.id) ?? ""
            let pretty = await Task.detached(priority: .userInitiated) { Self.prettyJSON(raw) }.value
            guard currentLayer?.id == layer.id else { return }
            currentRawJSON = pretty
        } catch {
            errorText = String(describing: error)
        }
    }

    nonisolated private static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return text }
        return String(decoding: pretty, as: UTF8.self)
    }

    // MARK: - Extractability

    /// Runs the rules (finding and, once, crawling the FeatureServer twin), persists the
    /// verdict, and refreshes the row and the page.
    func assessCurrentLayer() async {
        guard let crawler, let database, let layer = currentLayer else { return }
        isAssessing = true
        defer { isAssessing = false }
        do {
            let result = try await crawler.assess(layerID: layer.id)
            guard currentLayer?.id == layer.id else { return }
            assessment = result
            currentLayer = try await database.layer(id: layer.id)
            try await reloadTree()
        } catch {
            if currentLayer?.id == layer.id { probeError = String(describing: error) }
        }
    }

    /// The count probe: confirms extractability and records the count, or overturns it with
    /// the server's message.
    func probeCurrentLayer() async {
        guard let crawler, let database, let layer = currentLayer else { return }
        probing = true
        probeError = nil
        defer { probing = false }
        do {
            try await crawler.probeCount(layerID: layer.id)
        } catch {
            probeError = String(describing: error)
        }
        do {
            currentLayer = try await database.layer(id: layer.id)
            assessment = try await crawler.assess(layerID: layer.id)
            try await reloadTree()
        } catch {
            errorText = String(describing: error)
        }
    }

    // MARK: - Crawling

    private func crawlService(_ serviceID: Int64) async {
        guard let crawler else { return }
        let id = NodeID.service(serviceID)
        loadingNodes.insert(id)
        nodeErrors[id] = nil
        defer { loadingNodes.remove(id) }
        do {
            try await crawler.crawlService(serviceID: serviceID)
            try await reloadTree()
        } catch {
            nodeErrors[id] = String(describing: error)
        }
    }

    /// ⌘R: re-fetches the current node from the server.
    func refreshCurrent() async {
        guard let crawler, let server = currentServer else { return }
        errorText = nil
        do {
            switch selection {
            case .none, .server?:
                try await crawler.shallowCrawl(serverID: server.id)
            case .folder(_, let path)?:
                try await crawler.crawlDirectory(serverID: server.id, folderPath: path)
            case .service(let id)?:
                await crawlService(id)
            case .layer(let id)?:
                try await crawler.crawlLayer(layerID: id)
            }
            try await reloadServers()
            try await reloadTree()
            await select(selection)
        } catch {
            errorText = String(describing: error)
        }
    }

    /// Crawls every Map/Feature service under the current server, reporting progress.
    /// Cancellable via `cancelDeepCrawl()`.
    func deepCrawlCurrentServer() async {
        guard deepCrawlTask == nil else { return }
        let task = Task { await runDeepCrawl() }
        deepCrawlTask = task
        await task.value
        deepCrawlTask = nil
    }

    func cancelDeepCrawl() {
        deepCrawlTask?.cancel()
    }

    private func runDeepCrawl() async {
        guard let crawler, let server = currentServer else { return }
        deepCrawlStatus = "Listing services…"
        defer { deepCrawlStatus = nil }
        do {
            let failures = try await crawler.deepCrawl(serverID: server.id) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .service(let name, let layers): self.deepCrawlStatus = "\(name): \(layers) layers"
                    case .directory(let folder, let count): self.deepCrawlStatus = "\(folder.isEmpty ? "root" : folder): \(count) services"
                    case .layer(let name): self.deepCrawlStatus = name
                    case .failed(let what, _): self.deepCrawlStatus = "\(what) failed"
                    }
                }
            }
            try await reloadServers()
            try await reloadTree()
            if !failures.isEmpty {
                errorText = "\(failures.count) service\(failures.count == 1 ? "" : "s") failed to crawl: "
                    + failures.compactMap { if case .failed(let what, _) = $0 { return what } else { return nil } }.joined(separator: ", ")
            }
        } catch is CancellationError {
            errorText = nil
        } catch {
            errorText = String(describing: error)
        }
    }

    // MARK: - URL intake

    func beginURLEdit() {
        urlDraft = pathContent?.url.absoluteString ?? ""
        isEditingURL = true
    }

    func cancelURLEdit() {
        isEditingURL = false
    }

    /// Return in the URL field: a known server navigates straight there; an unknown one opens
    /// the Add-server sheet with the resolved node preview.
    func submitURL() async {
        let text = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { isEditingURL = false; return }
        errorText = nil
        do {
            let location = try ArcGISURL.parse(text)
            guard let database else { return }
            if try await database.server(rootURL: location.rootURL) != nil {
                isEditingURL = false
                await open(text, friendlyName: nil)
            } else {
                isEditingURL = false
                pendingAdd = PendingAdd(text: text, location: location)
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    /// A URL given at launch (`--open`): known servers navigate, unknown ones are added with
    /// the host as their name — no sheet, since nobody is there to fill it in.
    func openFromLaunch(_ text: String) async {
        await open(text, friendlyName: nil)
    }

    /// Registers a new server from the Add-server sheet.
    func addServer(_ pending: PendingAdd, friendlyName: String) async {
        pendingAdd = nil
        await open(pending.text, friendlyName: friendlyName)
    }

    /// Opens any ArcGIS URL: registers or touches its server, crawls as needed, and lands on
    /// the node it names.
    private func open(_ text: String, friendlyName: String?) async {
        guard let crawler else { return }
        let root = (try? ArcGISURL.parse(text))?.rootURL.absoluteString ?? text
        openingStatus = OpeningStatus(url: root, step: "Reading the service directory…")
        defer { openingStatus = nil }
        do {
            let opened = try await crawler.open(text, friendlyName: friendlyName, progress: { event in
                Task { @MainActor in self.openingProgress(event) }
            })
            openingStatus?.step = "Building the tree…"
            try await reloadServers()
            if currentServer?.id != opened.server.id {
                currentServer = opened.server
                expanded = [.server(opened.server.id)]
            }
            try await reloadTree()
            // Expand the ancestors so the target row is visible, then select it.
            if let service = opened.service {
                var path = ""
                for part in service.folderPath.split(separator: "/") {
                    path = path.isEmpty ? String(part) : path + "/" + part
                    expanded.insert(.folder(serverID: opened.server.id, path: path))
                }
                expanded.insert(.service(service.id))
            } else if let folder = opened.location.folderPath {
                var path = ""
                for part in folder.split(separator: "/") {
                    path = path.isEmpty ? String(part) : path + "/" + part
                    expanded.insert(.folder(serverID: opened.server.id, path: path))
                }
            }
            if let layer = opened.layer {
                await select(.layer(layer.id))
            } else if let service = opened.service {
                await select(.service(service.id))
            } else if let folder = opened.location.folderPath {
                await select(.folder(serverID: opened.server.id, path: folder))
            } else {
                await select(.server(opened.server.id))
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    private func openingProgress(_ event: CrawlEvent) {
        guard openingStatus != nil else { return }
        switch event {
        case .directory(let folder, let services):
            openingStatus?.step = "Listed \(folder.isEmpty ? "the root" : folder): \(services) services"
        case .service(let name, let layers):
            openingStatus?.step = "Read \(name): \(layers) layers"
        case .layer(let name):
            openingStatus?.step = "Reading \(name)…"
        case .failed(let what, let error):
            openingStatus?.step = "\(what): \(error)"
        }
    }

    // MARK: - Server management

    func rename(_ server: ServerRecord, to name: String) async {
        guard let database else { return }
        do {
            try await database.renameServer(id: server.id, friendlyName: name)
            try await reloadServers()
            try await reloadTree()
            await select(selection)
        } catch { errorText = String(describing: error) }
    }

    func saveSettings(_ server: ServerRecord, name: String, origin: String, referer: String) async {
        guard let database else { return }
        do {
            try await database.renameServer(id: server.id, friendlyName: name)
            try await database.setHeaderOverrides(serverID: server.id, origin: origin, referer: referer)
            try await reloadServers()
            try await reloadTree()
            await select(selection)
        } catch { errorText = String(describing: error) }
    }

    func forget(_ server: ServerRecord) async {
        guard let database else { return }
        do {
            try await database.forgetServer(id: server.id)
            try await reloadServers()
            if currentServer?.id == server.id {
                currentServer = nil
                tree = nil
                expanded = []
                await select(nil)
                if let next = servers.first { await selectServer(next.id) }
            }
        } catch { errorText = String(describing: error) }
    }

    func dismissError() { errorText = nil }
}

// MARK: - Transfers

extension AppModel {
    /// The run the strip shows: running > paused > latest.
    var headlineRun: TransferRun? {
        runs.first { $0.status == .running } ?? runs.first { $0.status == .paused } ?? runs.first
    }

    func outputPath(for layer: LayerRecord, service: ServiceRecord) -> URL {
        guard let server = currentServer else { return downloadDirectory }
        return Exporter.outputPath(directory: downloadDirectory, server: server, service: service, layer: layer, format: .geoParquet)
    }

    func reloadRuns() async {
        guard let database else { return }
        do {
            let records = try await database.downloads()
            var built = [TransferRun]()
            for record in records {
                let layer = try? await database.layer(id: record.layerID)
                var service: ServiceRecord? = nil
                if let layer { service = try? await database.service(id: layer.serviceID) }
                var server: ServerRecord? = nil
                if let service { server = try? await database.server(id: service.serverID) }
                let chunks: [ChunkStatus]
                if let live = liveChunks[record.id] { chunks = live }
                else if record.status == .running || record.status == .paused || record.status == .failed || record.status == .cancelled {
                    chunks = (try? await database.chunks(downloadID: record.id).map(\.status)) ?? []
                } else { chunks = [] }
                built.append(TransferRun(record: record, layerName: layer?.name ?? "layer \(record.layerID)",
                                         serviceName: service?.shortName ?? "", serverName: server?.friendlyName ?? "",
                                         progress: liveProgress[record.id], chunks: chunks, startedRunningAt: runStarted[record.id]))
            }
            runs = built
        } catch {
            transfersError = String(describing: error)
        }
    }

    func startDownload(_ request: DownloadRequest) async {
        guard let engine, let database else { return }
        transfersError = nil
        do {
            let record = try await engine.start(request) { [weak self] progress in
                Task { @MainActor in await self?.progressed(progress) }
            }
            runStarted[record.id] = Date()
            showTransfers = true
            await reloadRuns()
            _ = database
        } catch DownloadError.notExtractable(let reason) {
            transfersError = reason
        } catch {
            transfersError = String(describing: error)
        }
    }

    private func progressed(_ progress: DownloadProgress) async {
        liveProgress[progress.downloadID] = progress
        if runStarted[progress.downloadID] == nil { runStarted[progress.downloadID] = Date() }
        if let database { liveChunks[progress.downloadID] = (try? await database.chunks(downloadID: progress.downloadID).map(\.status)) ?? [] }
        if progress.status != .running {
            liveProgress[progress.downloadID] = nil
            liveChunks[progress.downloadID] = nil
            runStarted[progress.downloadID] = nil
            if progress.status == .failed, let message = progress.message, message.contains("already exists") {
                // The output exists: ask before overwriting (SPEC §5.7). Re-run with consent.
                if let record = try? await database?.download(id: progress.downloadID), let layer = currentLayer, layer.id == record.layerID {
                    var request = DownloadRequest(layerID: record.layerID, outputDirectory: downloadDirectory)
                    request.whereClause = record.whereClause
                    request.outWkid = record.outWkid
                    request.domainLabels = record.domainLabels
                    request.overwrite = true
                    pendingOverwrite = request
                    try? await database?.deleteDownload(id: record.id)
                }
            }
            if progress.status == .complete, let layer = currentLayer { _ = layer }
        }
        await reloadRuns()
    }

    func resumeDownload(_ id: Int64) async {
        guard let engine else { return }
        transfersError = nil
        do {
            _ = try await engine.resume(downloadID: id, overwrite: true, outputDirectory: downloadDirectory) { [weak self] progress in
                Task { @MainActor in await self?.progressed(progress) }
            }
            runStarted[id] = Date()
            await reloadRuns()
        } catch {
            transfersError = String(describing: error)
        }
    }

    func cancelDownload(_ id: Int64) {
        Task { await engine?.cancel(downloadID: id) }
    }

    func removeDownload(_ id: Int64) async {
        guard let database else { return }
        do {
            let record = try await database.download(id: id)
            if let staging = record.stagingPath { try? FileManager.default.removeItem(atPath: staging) }
            try await database.deleteDownload(id: id)
            await reloadRuns()
        } catch {
            transfersError = String(describing: error)
        }
    }

    func chooseDownloadDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = downloadDirectory
        panel.prompt = "Use this folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        downloadDirectory = url
        Task { try? await database?.setSetting("download_dir", url.path) }
    }

    func reveal(_ path: String?) {
        guard let path else { return }
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path).deletingLastPathComponent()])
        }
    }
}

// MARK: - Column search

extension AppModel {
    var isSearching: Bool { !columnSearch.trimmingCharacters(in: .whitespaces).isEmpty }

    func runColumnSearch() async {
        guard let database else { return }
        let text = columnSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { searchHits = []; searchError = nil; return }
        var options = search
        options.text = text
        options.serverID = searchAllServers ? nil : currentServer?.id
        do {
            searchHits = try await database.searchFields(options)
            searchUncrawled = try await database.uncrawledServiceCount(serverID: options.serverID)
            searchError = nil
        } catch {
            searchHits = []
            searchError = String(describing: error)
        }
    }

    /// Opens the hit's layer, switching server if needed, and clears the search.
    func navigate(toHit hit: FieldSearchHit) async {
        columnSearch = ""
        if currentServer?.id != hit.serverID {
            await selectServer(hit.serverID)
        }
        if let service = try? await database?.service(id: hit.serviceID) {
            var path = ""
            for part in service.folderPath.split(separator: "/") {
                path = path.isEmpty ? String(part) : path + "/" + part
                expanded.insert(.folder(serverID: hit.serverID, path: path))
            }
        }
        expanded.insert(.service(hit.serviceID))
        await select(.layer(hit.layerID))
    }

    /// Tree rows matching the filter box: every node whose name contains the text, with its
    /// usual indent, regardless of what is expanded.
    var filteredRows: [TreeRowItem] { filtered().rows }
    /// Matches beyond the cap, so the tree can say "keep typing".
    var filteredOverflow: Int { filtered().overflow }
    static let filterRowCap = 300

    private func filtered() -> (rows: [TreeRowItem], overflow: Int) {
        guard let tree else { return ([], 0) }
        let needle = treeFilter.trimmingCharacters(in: .whitespaces)
        if let cached = filterCache, cached.needle == needle, cached.version == treeVersion {
            return (cached.rows, cached.overflow)
        }
        var rows = [TreeRowItem]()
        var overflow = 0
        func walk(_ nodes: [TreeNode]) {
            for node in nodes {
                if node.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    if rows.count < Self.filterRowCap {
                        rows.append(TreeRowItem(node: node, indent: Self.indentPublic(for: node)))
                    } else {
                        overflow += 1
                    }
                }
                walk(node.children)
            }
        }
        walk(tree.children)
        filterCache = (needle, treeVersion, rows, overflow)
        return (rows, overflow)
    }

    static func indentPublic(for node: TreeNode) -> CGFloat {
        switch node.kind {
        case .server: return 0
        case .folder, .service: return 14 + 18 * CGFloat(node.folderDepth)
        case .layer, .table: return 14 + 18 * CGFloat(node.folderDepth) + 20
        }
    }
}

// MARK: - Map

extension AppModel {
    /// Opens the layer a finished download came from, on the Map tab, showing the stored file.
    func showStoredMap(_ record: DownloadRecord) async {
        guard let database, let layer = try? await database.layer(id: record.layerID) else { return }
        let service = try? await database.service(id: layer.serviceID)
        if let service, currentServer?.id != service.serverID { await selectServer(service.serverID) }
        expanded.insert(.service(layer.serviceID))
        await select(.layer(layer.id))
        layerTab = .map
        mapSession?.source = .stored(record.id)
    }

    /// Hands the Query tab's latest preview to the map.
    func syncMapSources() {
        guard let mapSession else { return }
        mapSession.querySet = querySession?.lastFeatureSet
        mapSession.queryWkid = querySession?.lastFeatureSetWkid
        if let layer = currentLayer {
            mapSession.updateStoredRuns(runs.filter { $0.record.layerID == layer.id && $0.status == .complete }.map(\.record))
        }
    }
}

extension AppModel {
    /// Removes every run that is not running (records and any staging file); output files stay.
    func clearFinishedDownloads() async {
        guard let database else { return }
        for run in runs where run.status != .running {
            if let staging = run.record.stagingPath { try? FileManager.default.removeItem(atPath: staging) }
            try? await database.deleteDownload(id: run.id)
        }
        await reloadRuns()
    }
}

extension AppModel {
    /// Day, night, or follow the system; remembered in the app database.
    func setAppearance(_ scheme: ColorScheme?) {
        appearanceOverride = scheme
        let value: String? = scheme == .light ? "light" : (scheme == .dark ? "dark" : nil)
        Task { try? await database?.setSetting("appearance", value) }
    }
}

/// What the app is doing while a server opens, for the opening page.
struct OpeningStatus: Equatable {
    var url: String
    var step: String
}
