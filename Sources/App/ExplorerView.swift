import SwiftUI
import ArcGISKit

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
            HStack(spacing: 0) {
                ServerTree()
                    .frame(width: 288)
                Rectangle().fill(Palette.line).frame(width: 1)
                DetailPane()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .ignoresSafeArea(.container, edges: .top)
        .onAppear { FieldFocus.install() }
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

/// 48px title row: room for the traffic lights, the path bar, the column search field.
private struct TitleBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Color.clear.frame(width: 64)   // traffic lights live here
            PathBar()
            ColumnSearchField()
            AppearanceToggle()
        }
        .padding(.trailing, 14)
        .frame(height: 48)
        .background(Palette.panel)
        .gesture(WindowDragGesture())
    }
}

/// Verbatim error text spanning the top of the page: Retry where the step can run again,
/// Dismiss always.
private struct ErrorBanner: View {
    let message: String
    let retry: (@MainActor () async -> Void)?
    let dismiss: () -> Void
    @State private var retrying = false

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
                if retrying {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Retry") {
                        retrying = true
                        Task { await retry(); retrying = false }
                    }
                    .buttonStyle(LinkButtonStyle(size: 12.5))
                }
            }
            Button("Dismiss", action: dismiss).buttonStyle(LinkButtonStyle(size: 12.5))
        }
        .padding(.horizontal, 36).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line2).frame(height: 1) }
        .shadow(color: .black.opacity(0.25), radius: 9, y: 6)
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
@MainActor
enum FieldFocus {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            guard let window = event.window,
                  let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                  let field = editor.delegate as? NSView else { return event }
            let inField = field.convert(field.bounds, to: nil).contains(event.locationInWindow)
            if !inField { window.makeFirstResponder(nil) }
            return event
        }
    }
}
