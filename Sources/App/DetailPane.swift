import SwiftUI
import RumenKit

/// Right of the tree: the page for the selected node, or the invitation when nothing is.
struct DetailPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.bg
            pageContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    @ViewBuilder private var pageContent: some View {
        Group {
            if let opening = model.openingStatus {
                OpeningPage(status: opening)
            } else if model.isSearching {
                ColumnSearchResults()
            } else if model.currentServer == nil {
                StartPage()
            } else {
            switch model.selection {
            case .none:
                EmptyState()
            case .server?:
                if let tree = model.tree { DirectoryPage(title: tree.name, subtitle: serverSubtitle, nodes: tree.children) }
            case .folder(_, let path)?:
                if let node = model.tree?.find(.folder(serverID: model.currentServer?.id ?? 0, path: path)) {
                    let listed = node.fetchedAt.map { ", listed \(Age.text($0))" } ?? ""
                    DirectoryPage(title: node.name, subtitle: "Folder on \(model.currentServer?.friendlyName ?? "")\(listed).",
                                  nodes: node.children, error: node.lastError,
                                  isRetrying: model.loadingNodes.contains(node.id),
                                  retry: { await model.retryFolder(path) })
                }
            case .service(let id)?:
                if let service = model.currentService, let node = model.tree?.find(.service(id)) {
                    ServicePage(service: service, node: node)
                }
            case .layer?:
                if let layer = model.currentLayer, let service = model.currentService {
                    LayerPage(layer: layer, service: service, fields: model.currentFields)
                }
            }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.bg)
        .clipped()
    }

    private var serverSubtitle: String {
        guard let server = model.currentServer else { return "" }
        if server.kind == .ogc {
            let types = model.services.map(\.type.name).sorted().joined(separator: ", ")
            return "OGC endpoint at \(server.host)\(types.isEmpty ? "" : ": \(types)"). Cached \(Age.text(server.lastVisitedAt))."
        }
        let version = server.arcgisVersion.map { "ArcGIS Server \($0.formatted(.number.precision(.fractionLength(0...2))))" } ?? "ArcGIS Server"
        if server.kind == .service {
            return "\(version) at \(server.host): one service, reached with no services directory above it. Cached \(Age.text(server.lastVisitedAt))."
        }
        return "\(version) at \(server.host). Cached \(Age.text(server.lastVisitedAt))."
    }
}

/// "Paste an ArcGIS URL into the bar above, or press ⌘L" with two example shapes.
private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste an ArcGIS or OGC URL into the bar above, or press ⌘L")
                .font(.sheetDisplay(24))
                .foregroundStyle(Palette.ink)
            Caption("Any URL in an ArcGIS hierarchy works: a services root, a folder, a service, a layer, even a query someone sent you, or a service behind a proxy that hides the rest/services path. So does a WMS, WFS or WMTS endpoint, vendor parameters and all.")
            VStack(alignment: .leading, spacing: 6) {
                Text("https://gis.example.gov.uk/arcgis/rest/services").font(.sheetMono(12)).foregroundStyle(Palette.muted)
                Text("https://services3.arcgis.com/…/arcgis/rest/services/Trailheads/FeatureServer/0").font(.sheetMono(12)).foregroundStyle(Palette.muted)
                Text("https://apps.example.gov.uk/planning/api/v1/Map/3").font(.sheetMono(12)).foregroundStyle(Palette.muted)
                Text("https://maps.example.gov.uk/cgi-bin/mapserv?map=planning&service=WFS&request=GetCapabilities").font(.sheetMono(12)).foregroundStyle(Palette.muted)
            }
            Button("Open a URL") { model.beginURLEdit() }.buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.top, 22).padding(.horizontal, 36)
    }
}

/// A server or folder: its children as rows, in the tree's voice.
private struct DirectoryPage: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String
    let nodes: [TreeNode]
    /// A folder whose listing failed: the server's message, and Retry (M8).
    var error: String? = nil
    var isRetrying = false
    var retry: (@MainActor () async -> Void)? = nil

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.sheetDisplay(24)).foregroundStyle(Palette.ink).tracking(-0.24)
                Caption(subtitle)
            }
            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This folder could not be listed. What follows is what was cached before, if anything.")
                        .font(.sheetUI(13)).foregroundStyle(Palette.ink).frame(maxWidth: 720, alignment: .leading)
                    ErrorText(message: error)
                    if isRetrying {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Caption("Listing again…") }
                    } else if let retry {
                        AsyncButton("Retry", busy: "Listing…", action: retry).buttonStyle(LinkButtonStyle())
                    }
                }
            }
            let folders = nodes.filter { $0.kind == .folder }
            let services = nodes.filter { if case .service = $0.kind { return true } else { return false } }
            if nodes.isEmpty {
                Caption("Nothing listed here.")
            }
            if !folders.isEmpty {
                SectionHeading("Folders")
                ChildList(nodes: folders)
            }
            if !services.isEmpty {
                SectionHeading("Services")
                ChildList(nodes: services)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 22).padding(.horizontal, 36).padding(.bottom, 24)
        }
    }
}

/// Children of a folder or service as navigation rows: id or glyph, name, a line of detail,
/// the locator, and a chevron that answers the hover. Every row is a link.
private struct ChildList: View {
    let nodes: [TreeNode]

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(nodes) { node in
                ChildRow(node: node)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
        .frame(maxWidth: 880)
    }
}

private struct ChildRow: View {
    @Environment(AppModel.self) private var model
    let node: TreeNode
    @State private var hovered = false

    var body: some View {
        Button {
            Task { await model.select(node.id) }
        } label: {
            HStack(spacing: 10) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 8) {
                        Text(node.name).font(.sheetUI(13, .medium)).foregroundStyle(Palette.ink).lineLimit(1)
                        if case .service(let type) = node.kind { KindLabel(type: type) }
                    }
                    if let detail {
                        Caption(detail, size: 11, color: Palette.muted2).lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if node.lastError != nil {
                    Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.no)
                        .frame(width: 22, height: 15)
                } else {
                    ExtentLocator(extent: node.extent, frame: model.tree?.extent, style: locatorStyle, trusted: node.kind == .folder)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovered ? Palette.accent : Palette.muted2)
                    .offset(x: hovered ? 2 : 0)
                    .frame(width: 14)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 38)
            .background(hovered ? Palette.line.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTracking($hovered, hand: true)
        .help(node.lastError ?? "Open \(node.name)")
    }

    /// The layer id in mono, as in the tree; a glyph for folders and services.
    @ViewBuilder private var leading: some View {
        switch node.kind {
        case .layer, .table:
            Text(node.layerID.map(String.init) ?? "")
                .font(.sheetMono(11)).foregroundStyle(Palette.muted2)
                .frame(width: 22, alignment: .trailing)
        case .folder:
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 22)
        case .service, .server:
            Image(systemName: "square.stack.3d.up").font(.system(size: 12)).foregroundStyle(Palette.muted).frame(width: 22)
        }
    }

    private var detail: String? {
        switch node.kind {
        case .layer:
            switch node.extractable {
            case true?: return "Layer · extractable"
            case false?: return "Layer · not extractable"
            default: return "Layer"
            }
        case .table:
            return "Table · no geometry"
        case .service:
            if node.fetchedAt == nil { return node.isExpandable ? "Not crawled yet; opens from the server" : nil }
            let layers = node.children.filter { $0.kind == .layer }.count
            let tables = node.children.filter { $0.kind == .table }.count
            var parts = [String]()
            if layers > 0 { parts.append(layers == 1 ? "1 layer" : "\(layers) layers") }
            if tables > 0 { parts.append(tables == 1 ? "1 table" : "\(tables) tables") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .folder:
            let folders = node.children.filter { $0.kind == .folder }.count
            let services = node.children.count - folders
            var parts = [String]()
            if node.lastError != nil { parts.append("Could not be listed") }
            if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
            if services > 0 { parts.append(services == 1 ? "1 service" : "\(services) services") }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .server:
            return nil
        }
    }

    private var locatorStyle: ExtentLocator.Style {
        switch node.kind {
        case .table: return .table
        default: return node.extractable == false ? .notExtractable : .normal
        }
    }
}

/// A service: identity, capabilities, and its layers and tables.
private struct ServicePage: View {
    @Environment(AppModel.self) private var model
    let service: ServiceRecord
    let node: TreeNode

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(service.shortName).font(.sheetDisplay(24)).foregroundStyle(Palette.ink).tracking(-0.24)
                    Text(service.type.name).font(.sheetUI(13)).foregroundStyle(Palette.muted2)
                }
                HStack(spacing: 4) {
                    Caption(subtitle)
                    AsyncButton("refresh", busy: "refreshing…") { await model.refreshCurrent() }.buttonStyle(LinkButtonStyle(size: 12.5))
                    Caption(".")
                }
            }
            if let error = model.nodeErrors[node.id] {
                VStack(alignment: .leading, spacing: 8) {
                    ErrorText(message: error)
                    AsyncButton("Retry", busy: "Retrying…") { await model.refreshCurrent() }.buttonStyle(LinkButtonStyle())
                }
            } else if model.loadingNodes.contains(node.id) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Caption("Loading layers from the server…")
                }
            }
            FactGrid(rows: facts)
            if !node.children.isEmpty {
                SectionHeading(node.children.contains { $0.kind == .table } ? "Layers and tables" : "Layers")
                ChildList(nodes: node.children)
            } else if !service.type.hasLayers {
                Caption("A \(service.type.name) has no queryable layers; it is listed, not downloaded.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 22).padding(.horizontal, 36).padding(.bottom, 24)
        }
    }

    private var subtitle: String {
        if service.type.isOGC {
            let version = service.ogcDetail.map { " \($0.version)" } ?? ""
            return "\(service.type.name)\(version) at \(model.currentServer?.host ?? "the endpoint"). Cached \(Age.text(service.fetchedAt)),"
        }
        let folder = service.folderPath.isEmpty ? "at the root" : "in the \(service.folderPath) folder"
        return "\(service.type.name) \(folder). Cached \(Age.text(service.fetchedAt)),"
    }

    private var facts: [(String, String, Bool)] {
        if let detail = service.ogcDetail { return ogcFacts(detail) }
        return [
            ("Capabilities", service.capabilities.map { Capabilities.parse($0).sorted().joined(separator: ", ") } ?? "—", false),
            ("Query formats", service.supportedQueryFormats ?? "—", false),
            ("Max record count", service.maxRecordCount?.grouped ?? "—", false),
            ("Tile cache", service.isTileCache == true ? "Yes, pre-rendered tiles" : (service.isTileCache == false ? "No" : "—"), false),
            ("Layers", String(node.children.filter { $0.kind == .layer }.count), false),
            ("Tables", String(node.children.filter { $0.kind == .table }.count), false),
            ("URL", service.url.absoluteString, true),
        ]
    }

    /// What an OGC service said about itself (M10).
    private func ogcFacts(_ d: OGCServiceDetail) -> [(String, String, Bool)] {
        func list(_ items: [String], empty: String = "—") -> String { items.isEmpty ? empty : items.joined(separator: ", ") }
        var rows: [(String, String, Bool)] = [
            ("Title", d.title ?? "—", false),
            ("Version", d.version, true),
            ("Operations", list(d.operations), false),
            ("Formats", list(d.formats), false),
        ]
        switch service.type {
        case .wfs:
            rows.append(("Paging", d.paging ? "Yes, \(d.countDefault?.grouped ?? "the server's default") per request" : "No, one request per type", false))
        case .wms:
            rows.append(("Max picture", d.maxWidth.map { "\($0.grouped) × \((d.maxHeight ?? $0).grouped) px" } ?? "Not stated", false))
        case .wmts:
            rows.append(("Tile matrix sets", list(d.tileMatrixSets.map { "\($0.identifier) (\($0.crs))" }), false))
        default: break
        }
        rows.append(("Layers", String(node.children.count), false))
        rows.append(("Abstract", d.abstract ?? "—", false))
        rows.append(("URL", service.url.absoluteString, true))
        return rows
    }
}

/// The fact list: label / value pairs in a four-column grid, values truncating not wrapping.
struct FactGrid: View {
    /// (label, value, isMono)
    let rows: [(String, String, Bool)]

    var body: some View {
        let pairs = stride(from: 0, to: rows.count, by: 2).map { Array(rows[$0..<min($0 + 2, rows.count)]) }
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                GridRow {
                    ForEach(Array(pair.enumerated()), id: \.offset) { index, fact in
                        Text(fact.0).font(.sheetUI(12.5)).foregroundStyle(Palette.muted)
                            .frame(width: index == 0 ? 136 : 126, alignment: .leading)
                        Text(fact.1)
                            .font(fact.2 ? .sheetMono(12) : .sheetUI(12.5))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1).truncationMode(.tail)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if pair.count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]); Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
        .frame(maxWidth: 880, alignment: .leading)
    }
}

/// Where the app is going and what the crawler is doing, while a server opens.
private struct OpeningPage: View {
    let status: OpeningStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Opening \(URL(string: status.url)?.host ?? status.url)")
                .font(.sheetDisplay(24)).foregroundStyle(Palette.ink).tracking(-0.24)
            Text(status.url).font(.sheetMono(12)).foregroundStyle(Palette.muted).textSelection(.enabled)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Caption(status.step).lineLimit(2)
            }
            Caption("Every folder and service is listed once; after that the server opens from cache.", color: Palette.muted2)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.top, 22).padding(.horizontal, 36)
    }
}

/// The first screen: known servers to pick from, and a field for any ArcGIS URL.
private struct StartPage: View {
    @Environment(AppModel.self) private var model
    @State private var draft = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.servers.isEmpty ? "Open a server" : "Where to?")
                        .font(.sheetDisplay(24)).foregroundStyle(Palette.ink).tracking(-0.24)
                    Caption(model.servers.isEmpty
                            ? "Paste any ArcGIS URL: a services root, a folder, a service, a layer, or a query someone sent you. A WMS, WFS or WMTS endpoint works too."
                            : "Pick a server you have opened before, or paste any ArcGIS or OGC URL.")
                }
                if !model.servers.isEmpty {
                    SectionHeading("Servers")
                    VStack(spacing: 0) {
                        ForEach(model.servers) { server in
                            StartServerRow(server: server, services: model.serverServiceCounts[server.id])
                            Rectangle().fill(Palette.line).frame(height: 1)
                        }
                    }
                    .frame(maxWidth: 880)
                }
                SectionHeading(model.servers.isEmpty ? "URL" : "Or paste a URL")
                HStack(spacing: 10) {
                    TextField("https://gis.example.gov.uk/arcgis/rest/services", text: $draft)
                        .textFieldStyle(SheetFieldStyle(mono: true))
                        .accessibilityLabel("URL to open")
                        .frame(maxWidth: 560)
                        .onSubmit { Task { await open() } }
                    AsyncButton("Open", busy: "Opening…") { await open() }
                        .buttonStyle(PrimaryButtonStyle(small: true))
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Caption("Any URL in the hierarchy works, for example …/arcgis/rest/services/Trailheads/FeatureServer/0. ⌘L edits the bar above.", color: Palette.muted2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 22).padding(.horizontal, 36).padding(.bottom, 24)
        }
    }

    private func open() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await model.openText(text)
    }
}

private struct StartServerRow: View {
    @Environment(AppModel.self) private var model
    let server: ServerRecord
    let services: Int?
    @State private var hovered = false
    @State private var forgetHovered = false
    @State private var editHovered = false
    @State private var confirmForget = false

    var body: some View {
        HStack(spacing: 6) {
            openButton
            Button {
                model.settingsServer = server
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(editHovered ? Palette.ink : Palette.muted2)
                    .frame(width: 22, height: 22)
                    .background(editHovered ? Palette.line : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTracking($editHovered, hand: true)
            .accessibilityLabel("Server settings")
            .help("Settings: name, cookie, Origin and Referer headers")
            Button {
                confirmForget = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(forgetHovered ? Palette.no : Palette.muted2)
                    .frame(width: 22, height: 22)
                    .background(forgetHovered ? Palette.line : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverTracking($forgetHovered, hand: true)
            .accessibilityLabel("Forget server")
            .help("Forget this server: cached metadata is removed, downloaded files are kept")
        }
        .confirmationDialog("Forget \(server.friendlyName)?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { Task { await model.forget(server) } }
        } message: {
            Text("Cached metadata for this server is removed. Downloaded files on disk are kept.")
        }
    }

    private var openButton: some View {
        AsyncButton { opening in
            HStack(spacing: 12) {
                Image(systemName: "server.rack").font(.system(size: 13)).foregroundStyle(Palette.muted).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.friendlyName).font(.sheetUI(13, .semibold)).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(server.rootURL.absoluteString).font(.sheetMono(11.5)).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Spacer(minLength: 12)
                // Opening a server is a crawl, not a navigation: the row says so where it
                // would otherwise say when it was last visited.
                if opening {
                    ProgressView().controlSize(.small)
                    Caption("Opening…", size: 11.5, color: Palette.accent)
                } else {
                    Caption(summary, size: 11.5, color: Palette.muted2).lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 46)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Palette.line.opacity(0.55) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        } action: {
            await model.selectServer(server.id)
        }
        .buttonStyle(.plain)
        .hoverTracking($hovered, hand: true)
    }

    private var summary: String {
        var parts = [String]()
        if let services { parts.append(services == 1 ? "1 service" : "\(services.grouped) services") }
        if let version = server.arcgisVersion {
            parts.append("ArcGIS Server \(version.formatted(.number.precision(.fractionLength(0...2))))")
        }
        parts.append("visited \(Age.text(server.lastVisitedAt))")
        return parts.joined(separator: " · ")
    }
}
