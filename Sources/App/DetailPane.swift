import SwiftUI
import ArcGISKit

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
            if model.isSearching {
                ColumnSearchResults()
            } else {
            switch model.selection {
            case .none:
                EmptyState()
            case .server?:
                if let tree = model.tree { DirectoryPage(title: tree.name, subtitle: serverSubtitle, nodes: tree.children) }
            case .folder(_, let path)?:
                if let node = model.tree?.find(.folder(serverID: model.currentServer?.id ?? 0, path: path)) {
                    DirectoryPage(title: node.name, subtitle: "Folder on \(model.currentServer?.friendlyName ?? "")", nodes: node.children)
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
        let version = server.arcgisVersion.map { "ArcGIS Server \($0.formatted(.number.precision(.fractionLength(0...2))))" } ?? "ArcGIS Server"
        return "\(version) at \(server.host). Cached \(Age.text(server.lastVisitedAt))."
    }
}

/// "Paste an ArcGIS URL into the bar above, or press ⌘L" with two example shapes.
private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Paste an ArcGIS URL into the bar above, or press ⌘L")
                .font(.sheetDisplay(24))
                .foregroundStyle(Palette.ink)
            Caption("Any URL in the hierarchy works: a services root, a folder, a service, a layer, even a query someone sent you.")
            VStack(alignment: .leading, spacing: 6) {
                Text("https://gis.example.gov.uk/arcgis/rest/services").font(.sheetMono(12)).foregroundStyle(Palette.muted)
                Text("https://services3.arcgis.com/…/arcgis/rest/services/Trailheads/FeatureServer/0").font(.sheetMono(12)).foregroundStyle(Palette.muted)
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

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.sheetDisplay(24)).foregroundStyle(Palette.ink).tracking(-0.24)
                Caption(subtitle)
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

private struct ChildList: View {
    @Environment(AppModel.self) private var model
    let nodes: [TreeNode]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(nodes) { node in
                Button {
                    Task { await model.select(node.id) }
                } label: {
                    HStack(spacing: 8) {
                        Text(node.name).font(.sheetUI(13)).foregroundStyle(Palette.ink)
                        if case .service(let type) = node.kind { KindLabel(type: type) }
                        if case .service = node.kind, node.fetchedAt == nil, node.isExpandable {
                            Caption("not crawled", size: 11, color: Palette.muted2)
                        }
                        Spacer()
                        ExtentLocator(extent: node.extent, frame: model.tree?.extent)
                    }
                    .frame(height: 27)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(Palette.line).frame(height: 1)
            }
        }
        .frame(maxWidth: 880)
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
                    Button("refresh") { Task { await model.refreshCurrent() } }.buttonStyle(LinkButtonStyle(size: 12.5))
                    Caption(".")
                }
            }
            if let error = model.nodeErrors[node.id] {
                VStack(alignment: .leading, spacing: 8) {
                    ErrorText(message: error)
                    Button("Retry") { Task { await model.refreshCurrent() } }.buttonStyle(LinkButtonStyle())
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
        let folder = service.folderPath.isEmpty ? "at the root" : "in the \(service.folderPath) folder"
        return "\(service.type.name) \(folder). Cached \(Age.text(service.fetchedAt)),"
    }

    private var facts: [(String, String, Bool)] {
        [
            ("Capabilities", service.capabilities.map { Capabilities.parse($0).sorted().joined(separator: ", ") } ?? "—", false),
            ("Query formats", service.supportedQueryFormats ?? "—", false),
            ("Max record count", service.maxRecordCount?.grouped ?? "—", false),
            ("Tile cache", service.isTileCache == true ? "Yes, pre-rendered tiles" : (service.isTileCache == false ? "No" : "—"), false),
            ("Layers", String(node.children.filter { $0.kind == .layer }.count), false),
            ("Tables", String(node.children.filter { $0.kind == .table }.count), false),
            ("URL", service.url.absoluteString, true),
        ]
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
