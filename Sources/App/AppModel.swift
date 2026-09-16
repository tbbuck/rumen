import Foundation
import SwiftUI
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
    private(set) var probing = false
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
    var appearanceOverride: ColorScheme?
    private(set) var errorText: String?
    private(set) var deepCrawlStatus: String?

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
            crawler = Crawler(client: client, database: db)
            try await reloadServers()
            if let first = servers.first { await selectServer(first.id) }
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    private func reloadServers() async throws {
        guard let database else { return }
        servers = try await database.servers()
        if let current = currentServer { currentServer = servers.first { $0.id == current.id } }
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
        currentService = nil
        currentLayer = nil
        currentFields = []
        currentRawJSON = nil
        assessment = nil
        probeError = nil
        guard let id, let database, let server = currentServer else { pathContent = nil; return }
        do {
            switch id {
            case .server:
                pathContent = PathBarContent.build(server: server)
            case .folder(_, let path):
                pathContent = PathBarContent.build(server: server, folderPath: path)
            case .service(let serviceID):
                let service = try await database.service(id: serviceID)
                currentService = service
                pathContent = PathBarContent.build(server: server, service: service)
                if !service.isCrawled && service.type.hasLayers {
                    await crawlService(serviceID)
                    currentService = try await database.service(id: serviceID)
                }
            case .layer(let layerID):
                let layer = try await database.layer(id: layerID)
                let service = try await database.service(id: layer.serviceID)
                currentService = service
                currentLayer = layer
                currentFields = try await database.fields(layerID: layerID)
                pathContent = PathBarContent.build(server: server, service: service, layer: layer)
                await assessCurrentLayer()
            }
        } catch {
            errorText = String(describing: error)
        }
    }

    /// Loads the pretty-printed raw JSON for the Raw tab on demand.
    func loadRawJSON() async {
        guard let database, let layer = currentLayer, currentRawJSON == nil else { return }
        do {
            let raw = try await database.layerRawJSON(id: layer.id) ?? ""
            currentRawJSON = Self.prettyJSON(raw)
        } catch {
            errorText = String(describing: error)
        }
    }

    private static func prettyJSON(_ text: String) -> String {
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
        do {
            assessment = try await crawler.assess(layerID: layer.id)
            currentLayer = try await database.layer(id: layer.id)
            try await reloadTree()
        } catch {
            probeError = String(describing: error)
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
        do {
            let opened = try await crawler.open(text, friendlyName: friendlyName)
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
