import SwiftUI
import ArcGISKit

/// 288px panel: the server header and the flattened tree of folders, services, layers.
struct ServerTree: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let server = model.currentServer {
                ServerHeader(server: server)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.visibleRows) { row in
                            TreeRow(row: row, frame: model.tree?.extent)
                        }
                    }
                    .padding(.bottom, 12)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No servers yet").font(.sheetUI(14, .bold)).foregroundStyle(Palette.ink)
                    Caption("Paste an ArcGIS URL into the bar above.", size: 11, color: Palette.muted2)
                }
                .padding(.horizontal, 16)
                Spacer()
            }
        }
        .padding(.top, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Palette.panel)
    }
}

/// Friendly name + "ArcGIS Server 10.91, cached 14 minutes ago"; context menu for the server.
private struct ServerHeader: View {
    @Environment(AppModel.self) private var model
    let server: ServerRecord
    @State private var confirmForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(server.friendlyName).font(.sheetUI(14, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
            Caption(caption, size: 11, color: Palette.muted2).lineLimit(1)
            if let status = model.deepCrawlStatus {
                HStack(spacing: 4) {
                    Caption("Deep crawl: \(status)", size: 11, color: Palette.accent).lineLimit(1)
                    Button("cancel") { model.cancelDeepCrawl() }.buttonStyle(LinkButtonStyle(size: 11))
                }
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { Task { await model.select(.server(server.id)) } }
        .contextMenu {
            Button("Rename…") { model.settingsServer = server }
            Button("Refresh") { Task { await model.refreshCurrent() } }
            Button("Deep crawl") { Task { await model.deepCrawlCurrentServer() } }
            Button("Settings…") { model.settingsServer = server }
            Divider()
            Button("Forget…") { confirmForget = true }
        }
        .confirmationDialog("Forget \(server.friendlyName)?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { Task { await model.forget(server) } }
        } message: {
            Text("Cached metadata for this server is removed. Downloaded files on disk are kept.")
        }
    }

    private var caption: String {
        let version = server.arcgisVersion.map { "ArcGIS Server \($0.formatted(.number.precision(.fractionLength(0...2))))" } ?? server.host
        return "\(version), cached \(Age.text(server.lastVisitedAt))"
    }
}

/// One node: chevron, layer id, name, kind, staleness, and its extent locator.
private struct TreeRow: View {
    @Environment(AppModel.self) private var model
    let row: TreeRowItem
    let frame: BoundingBox?

    private var node: TreeNode { row.node }
    private var isSelected: Bool { model.selection == node.id }
    private var isLoading: Bool { model.loadingNodes.contains(node.id) }
    private var isDimmed: Bool { node.extractable == false }
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            if isLoading {
                ProgressView().controlSize(.mini).frame(width: 10, height: 10)
            } else if node.isExpandable {
                Button {
                    Task { await model.toggleExpanded(node) }
                } label: {
                    Image(systemName: model.isExpanded(node.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.muted2)
                        .frame(width: 10, height: 10)
                }
                .buttonStyle(.plain)
            } else if let layerID = node.layerID {
                Text(String(layerID))
                    .font(.sheetMono(10.5))
                    .foregroundStyle(Palette.muted2)
                    .frame(width: 14, alignment: .trailing)
            } else {
                Color.clear.frame(width: 10, height: 10)
            }
            Text(node.name)
                .font(.sheetUI(13, isSelected ? .semibold : .regular))
                .foregroundStyle(isDimmed ? Palette.muted2 : Palette.ink)
                .lineLimit(1)
            if case .service(let type) = node.kind {
                KindLabel(type: type)
            }
            if Age.isStale(node.fetchedAt) {
                Caption("stale", size: 10.5, color: Palette.warn)
            }
            Spacer(minLength: 4)
            if model.nodeErrors[node.id] != nil {
                Image(systemName: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(Palette.no)
                    .frame(width: 22, height: 15)
            } else {
                ExtentLocator(extent: node.extent, frame: frame, style: locatorStyle)
            }
        }
        .padding(.leading, row.indent)
        .padding(.trailing, 14)
        .frame(height: 27)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Palette.accentSoft : (hovered ? Palette.line.opacity(0.55) : .clear))
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Palette.accent).frame(width: 2) }
        }
        .contentShape(Rectangle())
        .hoverTracking($hovered)
        .onTapGesture { Task { await model.select(node.id) } }
        .help(model.nodeErrors[node.id] ?? "")
    }

    private var locatorStyle: ExtentLocator.Style {
        switch node.kind {
        case .table: return .table
        default: return isDimmed ? .notExtractable : .normal
        }
    }
}
