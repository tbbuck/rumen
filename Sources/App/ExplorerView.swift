import SwiftUI
import RumenKit

/// The window: title bar with the path bar, then the tree beside the page, then the
/// transfers strip — the Directory layout.
struct ExplorerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            TitleBar()
            Rectangle().fill(Palette.line).frame(height: 1)
            HStack(alignment: .top, spacing: 0) {
                ServerTree()
                    .frame(width: model.treeWidth)
                PanelDivider()
                // The page gets exactly the space left and never more: a tab whose content wants
                // more height than the window has with the drawer open (a grid with a minimum
                // height under a query box) would otherwise grow the whole stack, which SwiftUI
                // then centres, pushing the title bar off the top and the tree down. Now such a
                // page is cut at the bottom instead, under the drawer, and the chrome stays put.
                GeometryReader { space in
                    DetailPane()
                        .frame(width: space.size.width, height: space.size.height, alignment: .top)
                }
                    // Errors sit at the top of the page, under the title bar, where a failed open
                    // is seen; run failures stay in the transfers drawer.
                    .overlay(alignment: .top) {
                        if let error = model.errorText {
                            ErrorBanner(message: error, retry: model.errorRetry) { model.dismissError() }
                                .transition(reduceMotion ? .identity : .move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.errorText)
                    .clipped()
            }
            if model.showTransfers { TransfersDrawer() } else { TransfersStrip() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.showTransfers)
        .background(Palette.bg)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rumen")
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { FieldFocus.install(); TitleBarZoom.install(model: model); HostingViews.install(model: model); FieldFocus.clearInitialFocus() }
        .sheet(item: $model.pendingAdd) { pending in
            AddServerSheet(pending: pending)
        }
        .sheet(item: $model.settingsServer) { server in
            ServerSettingsSheet(server: server)
        }
        .alert("Replace the existing file?", isPresented: Binding(get: { model.pendingOverwrite != nil }, set: { if !$0 { model.pendingOverwrite = nil } })) {
            Button("Replace", role: .destructive) {
                if let request = model.pendingOverwrite { Task { await model.startDownload(request) } }
                model.pendingOverwrite = nil
            }
            Button("Keep it", role: .cancel) { model.pendingOverwrite = nil }
        } message: {
            if let request = model.pendingOverwrite, let layer = model.currentLayer, let service = model.currentService {
                let path = model.outputPath(for: layer, service: service, format: request.format).path
                let age = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date).map { Age.text($0) } ?? "unknown age"
                Text("\(path)\nwritten \(age). Replacing it cannot be undone.")
                    .onAppear { _ = request }
            }
        }
        .overlay {
            if case .failed(let message) = model.phase {
                FatalView(message: message)
            }
        }
    }
}

/// The hairline between the tree and the page, with a 9px grab zone: drag to resize the tree
/// (220 to 560), double-click to put it back to 288. The width is remembered.
private struct PanelDivider: View {
    @Environment(AppModel.self) private var model
    @State private var startWidth: CGFloat?
    @State private var hovered = false

    var body: some View {
        Rectangle()
            .fill(hovered || startWidth != nil ? Palette.line2 : Palette.line)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { hovered = $0 }
                    .pointerStyle(.columnResize(directions: .all))
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = model.treeWidth }
                                model.setTreeWidth((startWidth ?? AppModel.defaultTreeWidth) + value.translation.width)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                Task { await model.saveTreeWidth() }
                            }
                    )
                    .onTapGesture(count: 2) {
                        model.setTreeWidth(AppModel.defaultTreeWidth)
                        Task { await model.saveTreeWidth() }
                    }
                    .help("Drag to resize the tree; double-click to reset")
            }
            .zIndex(1)
            .accessibilityHidden(true)   // a pointer affordance only; the tree's width is not read
    }
}

/// 48px title row: room for the traffic lights, the path bar, the column search field.
private struct TitleBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 14) {
            Color.clear.frame(width: 64)   // traffic lights live here
            PathBar()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.chromeFrames["path"] = $0 }
            ColumnSearchField()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.chromeFrames["search"] = $0 }
            AppearanceToggle()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.chromeFrames["appearance"] = $0 }
        }
        .padding(.trailing, 14)
        .frame(height: TitleBarZoom.height)
        .background(Palette.panel)
        .gesture(WindowDragGesture())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Title bar")
    }
}

/// Double-clicking the title strip does what the System Setting "Double-click a window's title
/// bar to" says (Zoom unless changed; Fill, Minimise, or nothing), as any title bar does. The
/// strip's controls keep their own double-clicks (a field selects text, a button acts), with one
/// exception: the path bar's empty area enters URL edit mode on the first click, and a second
/// click within the double-click interval cancels that and zooms instead, so the first click
/// is never held back waiting for a second.
@MainActor
enum TitleBarZoom {
    static let height: CGFloat = 48
    private static var monitor: Any?

    static func install(model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            let handled = MainActor.assumeIsolated { handle(event, model: model) }
            return handled ? nil : event
        }
    }

    /// True when the click was a title-strip double-click that has been acted on.
    private static func handle(_ event: NSEvent, model: AppModel) -> Bool {
        guard event.clickCount == 2, let window = event.window, let content = window.contentView,
              window.styleMask.contains(.fullSizeContentView), window.styleMask.contains(.titled) else { return false }
        let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        guard point.y >= 0, point.y <= height else { return false }
        if model.chromeFrames.values.contains(where: { $0.contains(point) }) {
            guard model.isEditingURL, let started = model.urlEditStartedAt,
                  Date().timeIntervalSince(started) < NSEvent.doubleClickInterval else { return false }
            model.cancelURLEdit()
        }
        perform(on: window)
        return true
    }

    /// The system's title-bar double-click action; the default when unset is Zoom.
    static func perform(on window: NSWindow) {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize" {
        case "Minimize":
            window.performMiniaturize(nil)
        case "Fill":
            if let screen = window.screen ?? NSScreen.main { window.setFrame(screen.visibleFrame, display: true, animate: true) }
        case "None":
            break
        default:
            window.performZoom(nil)
        }
    }
}

/// Verbatim error text spanning the top of the page: Retry where the step can run again,
/// Dismiss always.
private struct ErrorBanner: View {
    let message: String
    let retry: (@MainActor () async -> Void)?
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Palette.no)
            Text(message)
                .font(.sheetMono(11))
                .foregroundStyle(Palette.no)
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                AsyncButton("Retry", busy: "Retrying…", action: retry).buttonStyle(LinkButtonStyle(size: 12.5))
            }
            Button("Dismiss", action: dismiss).buttonStyle(LinkButtonStyle(size: 12.5))
        }
        .padding(.horizontal, 36).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line2).frame(height: 1) }
        .edgeShade(.bottom)
    }
}

/// The app database could not be opened or migrated: say so, verbatim, and stop.
private struct FatalView: View {
    let message: String
    var body: some View {
        ZStack {
            Palette.bg
            VStack(alignment: .leading, spacing: 12) {
                Text("The app database could not be opened").font(.sheetDisplay(24))
                ErrorText(message: message)
                Caption("The database lives at \(AppDatabase.defaultURL().path). Move it aside and relaunch to start afresh.")
            }
            .frame(maxWidth: 720)
            .padding(36)
        }
    }
}

/// A click anywhere outside the text field being edited ends the edit (AppKit leaves the
/// field editor in place until something else takes first responder, which plain views never do).
/// A title-bar field counts its whole box as inside — the padding, the magnifier, the clear
/// button — so a click that misses the text by a few points does not throw the edit away.
@MainActor
enum FieldFocus {
    private static var monitor: Any?

    /// No text field takes the keyboard at launch. AppKit hands the first text field in the
    /// window's key loop the focus when the window opens, so the first thing typed would land
    /// in the URL bar or the search box; the app asks for focus itself when it wants it (the
    /// tree after a server opens, a field on ⌘L or ⌘F).
    static func clearInitialFocus() {
        DispatchQueue.main.async {
            for window in NSApp.windows where window.isVisible {
                window.initialFirstResponder = nil
                if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                    window.makeFirstResponder(nil)
                }
            }
        }
    }

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView else { return event }
            var inField = field.convert(field.bounds, to: nil).contains(event.locationInWindow)
            if !inField, let area = (field as? ChromeNSTextField)?.focusArea, let content = window.contentView {
                let point = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                inField = area.contains(point)
            }
            if !inField { window.makeFirstResponder(nil) }
            return event
        }
    }
}

/// The AppKit view that hosts a window's SwiftUI content sits in the accessibility tree as a
/// nameless group between the window and the app's own named root, and the audit reported
/// each one as an element without a description (Apple's own SwiftUI apps show the same).
/// AppKit keeps it an element, so it is named for what it holds: "Rumen window",
/// "Preferences window", "Add a server sheet". Every window that becomes key is covered:
/// the main window, each sheet, and Preferences.
@MainActor
final class HostingViews: NSObject {
    private static var shared: HostingViews?
    private static var model: AppModel?

    static func install(model: AppModel) {
        guard shared == nil else { return }
        let observer = HostingViews()
        shared = observer
        Self.model = model
        // Window notifications post on the main thread; the selector form keeps that plain.
        NotificationCenter.default.addObserver(observer, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
        for window in NSApp.windows { name(window) }
    }

    @objc private func windowBecameKey(_ note: Notification) {
        Self.name(note.object as? NSWindow)
    }

    private static func name(_ window: NSWindow?) {
        guard let window, let content = window.contentView, content.isAccessibilityElement(),
              (content.accessibilityLabel() ?? "").isEmpty else { return }
        if window.isSheet {
            // A sheet has no title; the model knows which of the app's two it is.
            let which = model?.pendingAdd != nil ? "Add a server" : model?.settingsServer != nil ? "Server settings" : nil
            content.setAccessibilityLabel(which.map { "\($0) sheet" } ?? "Sheet")
        } else {
            content.setAccessibilityLabel(window.title.isEmpty ? "Rumen window" : "\(window.title) window")
        }
    }
}
