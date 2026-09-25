import SwiftUI
import RumenKit

/// The path bar: host segment, one segment per level, a mono tail, and an edit mode that
/// takes any pasted ArcGIS URL. Fills the title bar.
struct PathBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 2) {
            if model.isEditingURL {
                // Leaving the field by any route ends the edit, as a browser's address bar does:
                // a box left lit without the keyboard is what made ⌘L look like it had worked.
                ChromeTextField(text: $model.urlDraft, placeholder: "Paste an ArcGIS URL",
                                font: SheetFonts.mono(size: 12.5, weight: 400) ?? .monospacedSystemFont(ofSize: 12.5, weight: .regular),
                                accessibilityLabel: "URL", identifier: "location-field",
                                focusRequest: model.urlFocusRequest, focusOnAppear: true,
                                focusArea: model.chromeFrames["path"],
                                onFocusChange: { if !$0 { model.cancelURLEdit() } },
                                onSubmit: { Task { await model.submitURL() } },
                                onCancel: { model.cancelURLEdit() })
            } else if let content = model.pathContent, let server = model.currentServer {
                HostSegment(server: server)
                ForEach(Array(content.segments.dropFirst().enumerated()), id: \.offset) { index, segment in
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.muted2)
                        .frame(width: 12)
                        .accessibilityHidden(true)   // punctuation between segments
                    PathSegmentView(segment: segment, isCurrent: index == content.segments.count - 2)
                }
                Spacer(minLength: 8)
                Text(content.tail).font(.sheetMono(11)).foregroundStyle(Palette.muted2)
            } else {
                if !model.servers.isEmpty {
                    Button {
                        model.showRecents = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            Text("Servers").font(.sheetUI(13)).foregroundStyle(Palette.ink)
                        }
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Known servers")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Palette.muted2)
                        .frame(width: 12)
                        .accessibilityHidden(true)   // punctuation between segments
                }
                Text("Paste an ArcGIS URL, or press ⌘L")
                    .font(.sheetUI(13)).foregroundStyle(Palette.muted2)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .background(Palette.bg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(model.isEditingURL ? Palette.accent : Palette.line2, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { if !model.isEditingURL { model.beginURLEdit() } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Location")
        .accessibilityHint("Click the empty part to edit the URL")
        .popover(isPresented: $model.showRecents, arrowEdge: .bottom) {
            RecentServersPopover()
        }
    }
}

/// Server glyph + friendly name; click opens the recent servers popover.
private struct HostSegment: View {
    @Environment(AppModel.self) private var model
    let server: ServerRecord

    var body: some View {
        Button {
            model.showRecents = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack").font(.system(size: 11)).foregroundStyle(Palette.muted).accessibilityHidden(true)
                Text(server.friendlyName).font(.sheetUI(13)).foregroundStyle(Palette.ink)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Recent servers. Current server: \(server.friendlyName)")
        .help(server.rootURL.absoluteString)
    }
}

/// One level; click navigates there; the current segment is highlighted.
private struct PathSegmentView: View {
    @Environment(AppModel.self) private var model
    let segment: PathSegment
    let isCurrent: Bool
    @State private var hovered = false

    var body: some View {
        Button {
            Task { await model.select(segment.id) }
        } label: {
            Text(segment.label)
                .font(.sheetUI(13, isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent || hovered ? Palette.ink : Palette.muted)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(isCurrent ? Palette.accentSoft : (hovered ? Palette.line.opacity(0.7) : .clear), in: RoundedRectangle(cornerRadius: 5))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .hoverTracking($hovered, hand: !isCurrent)
    }
}

/// 190px "Find a column" field (⌘F). Escape clears it and hands the keyboard to the tree.
struct ColumnSearchField: View {
    @Environment(AppModel.self) private var model
    @State private var focused = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Palette.muted2)
            ChromeTextField(text: $model.columnSearch, placeholder: "Find a column",
                            font: SheetFonts.ui(size: 12.5) ?? .systemFont(ofSize: 12.5),
                            accessibilityLabel: "Find a column", identifier: "column-search-field",
                            focusRequest: model.columnSearchFocusRequest,
                            focusArea: model.chromeFrames["search"],
                            onFocusChange: { focused = $0 },
                            onCancel: {
                                model.columnSearch = ""
                                // Out of the field first, so Escape leaves it even with no tree to take over.
                                NSApp.keyWindow?.makeFirstResponder(nil)
                                model.focusTree()
                            })
            if !model.columnSearch.isEmpty {
                Button { model.columnSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.muted2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: 190, height: 30)
        .background(Palette.bg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(focused ? Palette.accent : Palette.line2, lineWidth: 1))
    }
}

/// Day · night · auto, three small icons in the title bar. Remembered across launches.
struct AppearanceToggle: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            AppearanceButton(symbol: "sun.max", help: "Day", isOn: model.appearanceOverride == .light) { model.setAppearance(.light) }
            AppearanceButton(symbol: "moon", help: "Night", isOn: model.appearanceOverride == .dark) { model.setAppearance(.dark) }
            AppearanceButton(symbol: "circle.lefthalf.filled", help: "Follow the system", isOn: model.appearanceOverride == nil) { model.setAppearance(nil) }
        }
        .padding(2)
        .background(Palette.bg, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.line2, lineWidth: 1))
    }
}

private struct AppearanceButton: View {
    let symbol: String
    let help: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Palette.accent : (hovered ? Palette.ink : Palette.muted2))
                .frame(width: 24, height: 24)
                .background(isOn ? Palette.accentSoft : (hovered ? Palette.line : .clear), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTracking($hovered, hand: !isOn)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(help)
    }
}
