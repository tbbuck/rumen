import Foundation
import SwiftUI
import AppKit
import Observation
import RumenKit
import SQLiteKit

/// One visible tree row: a node plus its indent. Indents follow DESIGN-TOKENS: folders and
/// root services at 14, +18 per folder level, layers a further 20 in.
struct TreeRowItem: Identifiable, Equatable {
    let node: TreeNode
    let indent: CGFloat
    var id: NodeID { node.id }
}

enum LayerTab: String, CaseIterable, Identifiable {
    case overview = "Overview", fields = "Fields", query = "Query", download = "Download", stored = "Stored", map = "Map", raw = "Raw"
    var id: String { rawValue }
}

/// A pasted URL whose server is not known yet, awaiting the Add-server sheet.
struct PendingAdd: Identifiable, Equatable {
    let text: String
    let rootURL: URL
    /// What the URL points at, in a sentence, for the sheet.
    let preview: String
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
    private(set) var storedSession: StoredSession?
    private(set) var probing = false
    private(set) var isAssessing = false
    private(set) var probeError: String?
    private var deepCrawlTask: Task<Void, Never>?
    var layerTab: LayerTab = .overview

    // Chrome
    var isEditingURL = false
    var urlDraft = ""
    /// When edit mode was last entered: a second click inside the double-click interval is a
    /// double-click on the title strip, not a click into the field.
    private(set) var urlEditStartedAt: Date?
    /// The title strip's controls (path bar, column search, appearance toggle) in window
    /// content coordinates, so a double-click between them can zoom the window.
    var chromeFrames: [String: CGRect] = [:]
    var pendingAdd: PendingAdd?
    var settingsServer: ServerRecord?
    var showRecents = false
    var columnSearch = ""
    var search = FieldSearchOptions(text: "")
    var searchAllServers = false
    private(set) var searchHits: [FieldSearchHit] = []
    private(set) var searchUncrawled = 0
    private(set) var searchFailedFolders = 0
    private(set) var searchError: String?
    var focusColumnSearch = false
    var treeFilter = ""
    /// Bumped to hand keyboard focus to the tree (after a server opens, on Escape or Down from a
    /// text field); the outline view watches it.
    private(set) var treeFocusRequest = 0
    func focusTree() { treeFocusRequest += 1 }

    /// The tree panel's width: 288 by DESIGN-TOKENS, draggable on its right edge, remembered.
    static let defaultTreeWidth: CGFloat = 288
    static let treeWidthRange: ClosedRange<CGFloat> = 220...560
    private(set) var treeWidth: CGFloat = AppModel.defaultTreeWidth

    func setTreeWidth(_ width: CGFloat) {
        treeWidth = min(max(width.rounded(), Self.treeWidthRange.lowerBound), Self.treeWidthRange.upperBound)
    }

    func saveTreeWidth() async {
        do { try await database?.setSetting("tree_width", String(Int(treeWidth))) } catch { report(error) }
    }
    var appearanceOverride: ColorScheme?
    private(set) var errorText: String?
    /// Runs the failed step again, when the banner can offer that.
    private(set) var errorRetry: (@MainActor () async -> Void)?
    private(set) var deepCrawlStatus: String?
    /// While a server is being opened: where, and what the crawler is doing right now.
    private(set) var openingStatus: OpeningStatus?
    /// Cached service counts per server, for the start page.
    private(set) var serverServiceCounts: [Int64: Int] = [:]
    /// Bumps whenever the tree is rebuilt; the outline view reloads on a change.
    private(set) var treeVersion = 0
    /// Every node flattened with a case- and diacritic-folded key, rebuilt when the tree is.
    @ObservationIgnored private var searchIndex: (version: Int, entries: [(key: [UInt8], row: TreeRowItem)])?
    @ObservationIgnored private var filterCache: (needle: String, version: Int, rows: [TreeRowItem])?

    // Transfers
    var showTransfers = false
    private(set) var runs: [TransferRun] = []
    private(set) var transfersError: String?
    /// Download defaults and network limits (M9), loaded at start and saved on every change.
    private(set) var preferences = Preferences(downloadDirectory: Preferences.initialDirectory)
    var downloadDirectory: URL { preferences.downloadDirectory }
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
            // Before anything creates the new support folder: carry across an install that
            // still keeps its state under the old name. A scratch home has nothing to adopt.
            if !AppPaths.isScratch { try AppDatabase.adoptLegacySupportDirectory() }
            try EngineSupport.install()   // before any DuckDB opens: the packaged build's extension folder
            let db = try AppDatabase(path: AppPaths.database.path)
            try await db.migrate()
            try await db.loadSpatial()
            database = db
            let crawler = Crawler(client: client, database: db)
            self.crawler = crawler
            engine = DownloadEngine(client: client, database: db, crawler: crawler, stagingDirectory: AppPaths.staging)
            preferences = try await Preferences.load(from: db)
            await client.setLimits(maxConcurrentPerHost: preferences.concurrency, retry: preferences.retryPolicy)
            await engine?.setConcurrency(preferences.concurrency)
            if let raw = try await db.setting("tree_width"), let width = Double(raw) { setTreeWidth(CGFloat(width)) }
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
            let count = serverServiceCounts[id].map { "\($0.grouped) services" } ?? "the services"
            openingStatus = OpeningStatus(url: server.rootURL.absoluteString, step: "Loading \(count) from cache…")
            defer { openingStatus = nil }
            currentServer = server
            try await reloadTree()
            if expanded.isEmpty { expanded = [.server(id)] }
            await select(.server(id))
            focusTree()
        } catch {
            report(error, retry: { [weak self] in await self?.selectServer(id) })
        }
    }

    private func reloadTree() async throws {
        guard let database, let server = currentServer else { tree = nil; return }
        services = try await database.services(serverID: server.id)
        let byService = try await database.layersByService(serverID: server.id)
        let folders = try await database.folders(serverID: server.id)
        layersByService = byService
        openingStatus?.step = "Building the tree…"
        let built = services
        tree = await Task.detached(priority: .userInitiated) {
            TreeBuilder.build(server: server, services: built, layersByService: byService, folders: folders)
        }.value
        treeVersion += 1
    }

    /// Lists a folder again after it failed (M8): the folder page's Retry.
    func retryFolder(_ path: String) async {
        guard let crawler, let server = currentServer else { return }
        clearError()
        let id = NodeID.folder(serverID: server.id, path: path)
        loadingNodes.insert(id)
        defer { loadingNodes.remove(id) }
        do {
            try await crawler.crawlFolder(serverID: server.id, path: path)
            try await reloadServers()
            try await reloadTree()
            await select(selection)
        } catch {
            try? await reloadTree()
            report(error, retry: { [weak self] in await self?.retryFolder(path) })
        }
    }

    func isExpanded(_ id: NodeID) -> Bool { expanded.contains(id) }

    /// The outline view's disclosure changed: mirror it. Expanding an uncrawled service crawls it.
    func setExpanded(_ node: TreeNode, _ on: Bool) async {
        if on {
            if !expanded.contains(node.id) { await toggleExpanded(node) }
        } else {
            expanded.remove(node.id)
        }
    }

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
                // An OGC layer has no query endpoint (M10): no Query tab, and the tabs it cannot
                // answer are not offered.
                querySession = service.type.isOGC ? nil
                    : QuerySession(layer: layer, service: service, fields: fields, info: info,
                                   client: client, database: database, connection: server.connection())
                let stored = storedRuns(for: layer.id)
                mapSession = MapSession(layer: layer, service: service, client: client, database: database,
                                        connection: server.connection(), storedRuns: stored, querySet: nil, queryWkid: nil)
                storedSession = StoredSession(layer: layer, database: database, runs: stored)
                if !availableTabs.contains(layerTab) { layerTab = .overview }
                await assessCurrentLayer()
            }
        } catch {
            report(error)
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
        storedSession = nil
    }

    /// Finished downloads of a layer whose file is recorded, newest first. A saved picture is
    /// a run but not a stored file: there are no rows in it to open.
    func storedRuns(for layerID: Int64) -> [DownloadRecord] {
        runs.filter { $0.record.layerID == layerID && $0.status == .complete && $0.record.outputPath != nil && !$0.record.format.isRaster }.map(\.record)
    }

    /// The tabs the current layer's page offers: every one for ArcGIS; for an OGC layer, the
    /// ones its protocol can answer (M10).
    var availableTabs: [LayerTab] {
        guard let service = currentService, service.type.isOGC else { return LayerTab.allCases }
        switch service.type {
        case .wfs: return [.overview, .fields, .download, .stored, .map, .raw]
        case .wms: return [.overview, .download, .map, .raw]
        default: return [.overview, .map, .raw]
        }
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
            report(error)
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
            report(error)
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
        clearError()
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
            report(error, retry: { [weak self] in await self?.refreshCurrent() })
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
            let failures = try await crawler.deepCrawl(serverID: server.id, concurrency: preferences.concurrency) { [weak self] event in
                Task { @MainActor in
                    guard let self else { return }
                    switch event {
                    case .service(let name, let layers): self.deepCrawlStatus = "\(name): \(layers) layer\(layers == 1 ? "" : "s")"
                    case .directory(let folder, let count): self.deepCrawlStatus = "\(folder.isEmpty ? "root" : folder): \(count) service\(count == 1 ? "" : "s")"
                    case .layer(let name): self.deepCrawlStatus = name
                    case .failed(let what, _): self.deepCrawlStatus = "\(what) failed"
                    }
                }
            }
            try await reloadServers()
            try await reloadTree()
            if !failures.isEmpty {
                report("\(failures.count) service\(failures.count == 1 ? "" : "s") failed to crawl: "
                       + failures.compactMap { if case .failed(let what, _) = $0 { return what } else { return nil } }.joined(separator: ", "),
                       retry: { [weak self] in await self?.deepCrawlCurrentServer() })
            }
        } catch is CancellationError {
            clearError()
        } catch {
            report(error, retry: { [weak self] in await self?.deepCrawlCurrentServer() })
        }
    }

    // MARK: - URL intake

    func beginURLEdit() {
        urlDraft = pathContent?.url.absoluteString ?? ""
        isEditingURL = true
        urlEditStartedAt = Date()
    }

    func cancelURLEdit() {
        isEditingURL = false
    }

    /// Return in the URL field: a known server navigates straight there; an unknown one opens
    /// the Add-server sheet with the resolved node preview.
    func submitURL() async {
        let text = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { isEditingURL = false; return }
        clearError()
        do {
            guard let database, let crawler else { return }
            let rootURL: URL
            let preview: String
            do {
                let location = try ArcGISURL.parse(text)
                rootURL = location.rootURL
                preview = Self.preview(of: location)
            } catch ArcGISURLError.notArcGIS {
                // Outside the rest/services shape (decision 19): a registered root may own it;
                // otherwise the URL is asked what it is — without the sheet's cookie and headers,
                // the open asks again with them — before an OGC endpoint is assumed (M10).
                if try ArcGISURL.resolve(text, against: servers) != nil || OGCURL.knownEndpoint(of: text, among: servers) != nil {
                    isEditingURL = false
                    await open(text, friendlyName: nil)
                    return
                }
                let bare = try ArcGISURL.bareURL(text)
                openingStatus = OpeningStatus(url: bare.absoluteString, step: "Asking \(bare.host ?? "the server") what this is…")
                let outcome: ArcGISProbeOutcome
                do {
                    outcome = try await crawler.probeArcGIS(text)
                } catch {
                    openingStatus = nil
                    throw error
                }
                openingStatus = nil
                switch outcome {
                case .found(let finding):
                    rootURL = finding.location.rootURL
                    preview = Self.preview(of: finding)
                case .refused(let error):
                    // ArcGIS, but it wants something: the sheet's advanced fields are the way in,
                    // and the open probes again with them, so this root is provisional.
                    rootURL = bare
                    preview = "This answered as ArcGIS but refused: \(error). If a signed-in browser's cookie or a particular Referer gets in, add it under Advanced and the open will ask again."
                case .notArcGIS(let reason):
                    let location = try OGCURL.parse(text)
                    rootURL = location.rootURL
                    preview = Self.preview(of: location, arcgisAttempt: reason)
                }
            }
            if try await database.server(rootURL: rootURL) != nil {
                isEditingURL = false
                await open(text, friendlyName: nil)
            } else {
                isEditingURL = false
                pendingAdd = PendingAdd(text: text, rootURL: rootURL, preview: preview)
            }
        } catch {
            report(error)
        }
    }

    /// The sentence the Add-server sheet leads with, for an ArcGIS URL.
    static func preview(of location: ArcGISLocation) -> String {
        let host = location.rootURL.host ?? "this server"
        if let layer = location.layerID, let service = location.servicePath, let type = location.serviceType {
            return "This is layer \(layer) of \(service) (\(type.name)) on \(host)."
        }
        if let service = location.servicePath, let type = location.serviceType {
            return "This is the \(type.name) service \(service) on \(host)."
        }
        if let folder = location.folderPath {
            return "This is the \(folder) folder on \(host)."
        }
        return "This is the services root of \(host)."
    }

    /// The same, for a URL outside the rest/services shape that answered as ArcGIS (decision 19).
    static func preview(of finding: ArcGISProbeFinding) -> String {
        switch finding {
        case .directory(let rootURL, _):
            return "This is an ArcGIS services directory on \(rootURL.host ?? "this server"), reached without the usual rest/services path."
        case .service(let serviceURL, let type, _):
            return "This is the \(type.name) service \(ArcGISURL.lastSegment(of: serviceURL)) on \(serviceURL.host ?? "this server"), reached on its own with no services directory above it (a proxy)."
        case .layer(let serviceURL, let type, let layerID, _):
            return "This is layer \(layerID) of the \(type.name) service \(ArcGISURL.lastSegment(of: serviceURL)) on \(serviceURL.host ?? "this server"), reached on its own with no services directory above it (a proxy)."
        }
    }

    /// The same, for an OGC endpoint: what will be asked of it, and what the URL named. With
    /// `arcgisAttempt`, what the URL said when first asked whether it was ArcGIS.
    static func preview(of location: OGCLocation, arcgisAttempt: String? = nil) -> String {
        let host = location.rootURL.host ?? "this server"
        var text = arcgisAttempt.map { "Asked ?f=json, \(host) did not answer as ArcGIS (\($0)), so it is taken for an OGC endpoint and will be asked for WMS, WFS and WMTS capabilities." }
            ?? "This looks like an OGC endpoint on \(host): it will be asked for WMS, WFS and WMTS capabilities."
        if let name = location.layerName {
            text += " The URL names \(location.serviceHint.map { "the \($0.name) layer " } ?? "")\(name)."
        } else if let hint = location.serviceHint {
            text += " The URL names its \(hint.name)."
        }
        return text
    }

    /// The root a pasted URL belongs to: ArcGIS by shape, a registered root outside that
    /// shape, else the OGC endpoint; nil when it is none of those.
    func rootURL(of text: String) -> URL? {
        (try? ArcGISURL.parse(text))?.rootURL
            ?? (try? ArcGISURL.resolve(text, against: servers))?.rootURL
            ?? (try? OGCURL.parse(text))?.rootURL
    }

    /// A URL given at launch (`--open`): known servers navigate, unknown ones are added with
    /// the host as their name — no sheet, since nobody is there to fill it in.
    func openFromLaunch(_ text: String) async {
        await open(text, friendlyName: nil)
    }

    /// Registers a new server from the Add-server sheet.
    func addServer(_ pending: PendingAdd, friendlyName: String, cookie: String = "",
                   origin: String = "", referer: String = "") async {
        guard pendingAdd != nil else { return }   // Return and the button can both fire; add once
        pendingAdd = nil
        await open(pending.text, friendlyName: friendlyName, headerOverrides: (origin, referer), cookie: cookie)
    }

    /// Opens any ArcGIS URL: registers or touches its server, crawls as needed, and lands on
    /// the node it names.
    private func open(_ text: String, friendlyName: String?,
                      headerOverrides: (origin: String?, referer: String?)? = nil, cookie: String? = nil) async {
        guard let crawler else { return }
        let root = rootURL(of: text)?.absoluteString ?? text
        openingStatus = OpeningStatus(url: root, step: "Opening…")
        defer { openingStatus = nil }
        do {
            let opened = try await crawler.open(text, friendlyName: friendlyName, headerOverrides: headerOverrides, cookie: cookie, progress: { event in
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
            focusTree()
            if !opened.problems.isEmpty {
                let listed = opened.problems.prefix(3).map { "\($0.folderPath): \($0.message)" }.joined(separator: "; ")
                let more = opened.problems.count > 3 ? " and \(opened.problems.count - 3) more" : ""
                report("\(opened.problems.count == 1 ? "One folder" : "\(opened.problems.count) folders") could not be listed: \(listed)\(more).",
                       retry: { [weak self] in await self?.refreshCurrent() })
            }
        } catch {
            report(error, retry: { [weak self] in
                await self?.open(text, friendlyName: friendlyName, headerOverrides: headerOverrides, cookie: cookie)
            })
            // The server may have been registered before the failure: go there rather than
            // leaving the user on whatever was open before.
            if let database, let root = rootURL(of: text),
               let server = try? await database.server(rootURL: root), currentServer?.id != server.id {
                await selectServer(server.id)
            }
        }
    }

    private func openingProgress(_ event: CrawlEvent) {
        guard openingStatus != nil else { return }
        switch event {
        case .directory(let folder, let services):
            openingStatus?.step = "Listed \(folder.isEmpty ? "the root" : folder): \(services) service\(services == 1 ? "" : "s")"
        case .service(let name, let layers):
            openingStatus?.step = "Read \(name): \(layers) layer\(layers == 1 ? "" : "s")"
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
        } catch { report(error) }
    }

    func saveSettings(_ server: ServerRecord, name: String, origin: String, referer: String, cookie: String) async {
        guard let database else { return }
        do {
            try await database.setCookie(serverID: server.id, cookie: cookie)
            try await database.renameServer(id: server.id, friendlyName: name)
            try await database.setHeaderOverrides(serverID: server.id, origin: origin, referer: referer)
            try await reloadServers()
            try await reloadTree()
            await select(selection)
        } catch { report(error) }
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
        } catch { report(error) }
    }

    func dismissError() { clearError() }

    /// Shows an error in the banner, with a Retry when the failed step can simply run again.
    func report(_ error: Error, retry: (@MainActor () async -> Void)? = nil) {
        report(String(describing: error), retry: retry)
    }

    func report(_ text: String, retry: (@MainActor () async -> Void)? = nil) {
        errorText = text
        errorRetry = retry
    }

    func clearError() {
        errorText = nil
        errorRetry = nil
    }
}

// MARK: - Transfers

extension AppModel {
    /// The run the strip shows: running > paused > latest.
    var headlineRun: TransferRun? {
        runs.first { $0.status == .running } ?? runs.first { $0.status == .paused } ?? runs.first
    }

    func outputPath(for layer: LayerRecord, service: ServiceRecord, format: ExportFormat = .geoParquet) -> URL {
        guard let server = currentServer else { return downloadDirectory }
        return Exporter.outputPath(directory: downloadDirectory, server: server, service: service, layer: layer, format: format)
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
                                         server: server, progress: liveProgress[record.id], chunks: chunks,
                                         startedRunningAt: runStarted[record.id]))
            }
            runs = built
            if let layer = currentLayer {
                let stored = storedRuns(for: layer.id)
                storedSession?.updateRuns(stored)
                mapSession?.updateStoredRuns(stored)
            }
        } catch {
            transfersError = String(describing: error)
        }
    }

    /// The Overview's primary button: a download with the preferences' defaults (format,
    /// spatial reference, domain labels) and every feature. The Download tab is where those
    /// change for one run.
    func downloadCurrentLayerWithDefaults() async {
        guard let layer = currentLayer else { return }
        var request = DownloadRequest(layerID: layer.id, outputDirectory: downloadDirectory)
        request.outWkid = preferences.outWkid(for: layer)
        request.format = preferences.defaultFormat
        request.domainLabels = preferences.domainLabels
        await startDownload(request)
    }

    /// A WMS layer's one download (M10): a picture of its extent, PNG unless the server offers
    /// GeoTIFF and the caller asks for it.
    func savePictureOfCurrentLayer(as format: ExportFormat = .png) async {
        guard let layer = currentLayer else { return }
        var request = DownloadRequest(layerID: layer.id, outputDirectory: downloadDirectory)
        request.format = format
        await startDownload(request)
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
                    request.format = record.format
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
        var next = preferences
        next.downloadDirectory = url
        Task { await setPreferences(next) }
    }

    /// Saves the preferences and applies the network limits to the client and the engine.
    func setPreferences(_ next: Preferences) async {
        preferences = next
        await client.setLimits(maxConcurrentPerHost: next.concurrency, retry: next.retryPolicy)
        await engine?.setConcurrency(next.concurrency)
        do { try await database?.save(next) } catch { report(error) }
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
            searchFailedFolders = try await database.failedFolders(serverID: options.serverID).count
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
    var filteredRows: [TreeRowItem] {
        guard let tree else { return [] }
        let needle = Self.searchKey(treeFilter.trimmingCharacters(in: .whitespaces))
        if let cached = filterCache, cached.needle == needle, cached.version == treeVersion { return cached.rows }
        if searchIndex?.version != treeVersion {
            var entries = [(key: [UInt8], row: TreeRowItem)]()
            func walk(_ nodes: [TreeNode]) {
                for node in nodes {
                    entries.append((Array(Self.searchKey(node.name).utf8), TreeRowItem(node: node, indent: Self.indentPublic(for: node))))
                    walk(node.children)
                }
            }
            walk(tree.children)
            searchIndex = (treeVersion, entries)
        }
        let needleBytes = Array(needle.utf8)
        // memmem: compiled C, so the scan costs the same in a Debug build as in Release.
        let rows = (searchIndex?.entries ?? []).filter { entry in
            needleBytes.isEmpty || entry.key.withUnsafeBufferPointer { key in
                needleBytes.withUnsafeBufferPointer { needle in
                    memmem(key.baseAddress, key.count, needle.baseAddress, needle.count) != nil
                }
            }
        }.map(\.row)
        filterCache = (needle, treeVersion, rows)
        return rows
    }

    /// Case- and diacritic-folded, so the per-keystroke match is a plain byte scan.
    private static func searchKey(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
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

    /// `--stored <id>`: the download by id, from cache.
    func showStoredDownload(id: Int64) async {
        guard let record = try? await database?.download(id: id) else { report("download \(id) not found"); return }
        await showStored(record)
    }

    /// Opens the layer a finished download came from, on the Stored tab, with that file selected.
    func showStored(_ record: DownloadRecord) async {
        guard let database, let layer = try? await database.layer(id: record.layerID) else { return }
        let service = try? await database.service(id: layer.serviceID)
        if let service, currentServer?.id != service.serverID { await selectServer(service.serverID) }
        expanded.insert(.service(layer.serviceID))
        await select(.layer(layer.id))
        layerTab = .stored
        storedSession?.selectedRunID = record.id
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
