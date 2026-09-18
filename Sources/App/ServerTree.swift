import SwiftUI
import ArcGISKit

/// 288px panel: the server header, the filter, and the outline of folders, services, layers.
struct ServerTree: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let server = model.currentServer {
                ServerHeader(server: server)
                TreeFilterField()
                TreeOutline(model: model, state: TreeState(version: model.treeVersion, filter: model.treeFilter,
                                                           selection: model.selection, expanded: model.expanded,
                                                           loading: model.loadingNodes, errors: model.nodeErrors,
                                                           focusRequest: model.treeFocusRequest))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    if let opening = model.openingStatus {
                        Text("Opening…").font(.sheetUI(14, .bold)).foregroundStyle(Palette.ink)
                        Caption(opening.step, size: 11, color: Palette.muted2).lineLimit(3)
                    } else if model.servers.isEmpty {
                        Text("No servers yet").font(.sheetUI(14, .bold)).foregroundStyle(Palette.ink)
                        Caption("Paste an ArcGIS URL into the bar above.", size: 11, color: Palette.muted2)
                    } else {
                        Text(model.servers.count == 1 ? "1 server known" : "\(model.servers.count) servers known").font(.sheetUI(14, .bold)).foregroundStyle(Palette.ink)
                        Caption("Pick one on the right.", size: 11, color: Palette.muted2)
                    }
                }
                .padding(.horizontal, 16)
                Spacer()
            }
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            HStack(alignment: .top, spacing: 8) {
                Text(server.friendlyName).font(.sheetUI(14, .bold)).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: 8)
                CloseServerButton()
            }
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server \(server.friendlyName)")
        .accessibilityHint("Click to open the server's page")
        .contextMenu {
            Button("Start page") { model.showStartPage() }
            Divider()
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
        let version: String
        if server.kind == .ogc {
            let types = model.services.map(\.type.name).sorted().joined(separator: ", ")
            version = types.isEmpty ? "OGC endpoint" : "OGC endpoint: \(types)"
        } else {
            let arcgis = server.arcgisVersion.map { "ArcGIS Server \($0.formatted(.number.precision(.fractionLength(0...2))))" } ?? server.host
            version = server.kind == .service ? "\(arcgis), one service with no directory" : arcgis
        }
        return "\(version), cached \(Age.text(server.lastVisitedAt))"
    }
}

/// Filters the tree by name; matching nodes are listed flat with their usual indent.
private struct TreeFilterField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(Palette.muted2)
            TextField("Filter", text: $model.treeFilter)
                .textFieldStyle(.plain)
                .font(.sheetUI(12))
                .foregroundStyle(Palette.ink)
                .accessibilityLabel("Filter the tree")
                .focused($focused)
                .onExitCommand { model.treeFilter = ""; focused = false; model.focusTree() }
                .onKeyPress(.downArrow) { model.focusTree(); return .handled }
                .onSubmit { model.focusTree() }
            if !model.treeFilter.isEmpty {
                Button { model.treeFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.muted2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the filter")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Palette.bg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Palette.accent : Palette.line2, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

/// Closes the server view and returns to the start page (all servers). Also ⌘⇧H.
private struct CloseServerButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovered = false

    var body: some View {
        Button {
            model.showStartPage()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovered ? Palette.ink : Palette.muted2)
                .frame(width: 20, height: 20)
                .background(hovered ? Palette.line : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTracking($hovered, hand: true)
        .accessibilityLabel("Close this server")
        .help("Close this server and go back to all servers (⌘⇧H)")
    }
}
