import SwiftUI
import ArcGISKit

/// 288px panel: the server header and the flattened tree of folders, services, layers.
struct ServerTree: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let server = model.currentServer {
                ServerHeader(server: server)
                TreeFilterField()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let filtering = !model.treeFilter.trimmingCharacters(in: .whitespaces).isEmpty
                        ForEach(filtering ? model.filteredRows : model.visibleRows) { row in
                            TreeRow(row: row, frame: model.tree?.extent)
                        }
                        if filtering, model.filteredOverflow > 0 {
                            Caption("\(AppModel.filterRowCap) shown, \(model.filteredOverflow) more match. Keep typing.", size: 11, color: Palette.muted2)
                                .padding(.horizontal, 16).padding(.top, 8)
                        }
                    }
                    .padding(.bottom, 12)
                }
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
                ChevronButton(expanded: model.isExpanded(node.id)) { Task { await model.toggleExpanded(node) } }
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
                    .help(locatorHelp)
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
        // One tap handler: a separate double-tap gesture would hold every single click until the
        // double-click window had passed. The second click of a double toggles expansion instead.
        .onTapGesture {
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                if node.isExpandable { Task { await model.toggleExpanded(node) } }
            } else {
                Task { await model.select(node.id) }
            }
        }
        .help(model.nodeErrors[node.id] ?? "")
    }

    private var locatorHelp: String {
        switch node.kind {
        case .table: return "A table: no geometry, so no extent."
        default:
            let what = isDimmed ? "Not extractable; its extent is outlined." : "Extent locator: the frame is this server's whole coverage, the box is where this \(node.kind == .folder ? "folder" : "node") sits within it."
            return what
        }
    }

    private var locatorStyle: ExtentLocator.Style {
        switch node.kind {
        case .table: return .table
        default: return isDimmed ? .notExtractable : .normal
        }
    }
}

/// Filters the tree by name; matching nodes are listed flat with their usual indent.
private struct TreeFilterField: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    /// Typed text; the model's filter follows it after a short pause so typing stays fluid.
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(Palette.muted2)
            TextField("Filter", text: $draft)
                .textFieldStyle(.plain)
                .font(.sheetUI(12))
                .foregroundStyle(Palette.ink)
                .focused($focused)
                .onExitCommand { draft = ""; model.treeFilter = ""; focused = false }
                .task(id: draft) {
                    if draft.isEmpty { model.treeFilter = ""; return }
                    try? await Task.sleep(for: .milliseconds(120))
                    if !Task.isCancelled { model.treeFilter = draft }
                }
                .onChange(of: model.treeFilter) { if model.treeFilter.isEmpty { draft = "" } }
            if !draft.isEmpty {
                Button { draft = ""; model.treeFilter = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.muted2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(Palette.bg, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? Palette.accent : Palette.line2, lineWidth: 1))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

/// The disclosure chevron with a full-height square hit target (UI feedback: clicking anywhere
/// around the chevron toggles).
private struct ChevronButton: View {
    let expanded: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(hovered ? Palette.ink : Palette.muted2)
                .frame(width: 10, height: 10)
                .frame(width: 22, height: 27)
                .background(hovered ? Palette.line : .clear, in: RoundedRectangle(cornerRadius: 4))
                .padding(.horizontal, -6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTracking($hovered)
        .help(expanded ? "Collapse" : "Expand")
    }
}
