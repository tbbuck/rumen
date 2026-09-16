import SwiftUI
import ArcGISKit

/// The window: title bar with the path bar, then the tree beside the page, then the
/// transfers strip — the Directory layout.
struct ExplorerView: View {
    @Environment(AppModel.self) private var model

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
            }
            TransfersStrip()
        }
        .background(Palette.bg)
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $model.pendingAdd) { pending in
            AddServerSheet(pending: pending)
        }
        .sheet(item: $model.settingsServer) { server in
            ServerSettingsSheet(server: server)
        }
        .overlay(alignment: .bottom) {
            if let error = model.errorText {
                ErrorBanner(message: error) { model.dismissError() }
                    .padding(.bottom, 52)
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
        }
        .padding(.trailing, 14)
        .frame(height: 48)
        .background(Palette.panel)
        .gesture(WindowDragGesture())
    }
}

/// Verbatim error text, dismissable, in a panel above the strip.
private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.no)
            ErrorText(message: message)
            Button("Dismiss", action: dismiss).buttonStyle(LinkButtonStyle(size: 12.5))
        }
        .padding(12)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.line2, lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 18, y: -6)
        .padding(.horizontal, 24)
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
