import SwiftUI
import ArcGISKit
import DuckDBKit

/// M0 entry point: opens and migrates the app database, then shows a diagnostic placeholder.
/// The real shell (sidebar, inspector, query, downloads, map) arrives with the UI spec.
@main
struct ArcGISExplorerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            PlaceholderView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
                .task { await model.start() }
        }
        .windowStyle(.titleBar)
    }
}
