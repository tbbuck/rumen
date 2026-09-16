import SwiftUI
import ArcGISKit
import DuckDBKit

/// Entry point. The window hides the system title bar so the path bar can be the spine
/// (UI-SPEC: "the URL is the spine"); `TitleBar` draws the 48px row behind the traffic lights.
@main
struct ArcGISExplorerApp: App {
    @State private var model = AppModel()

    /// `--open <url>`: navigate to an ArcGIS URL after launch (`open -a "ArcGIS Explorer" --args --open <url>`).
    static var openArgument: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--open"), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    init() {
        SheetFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            ExplorerView()
                .environment(model)
                .frame(minWidth: 1140, minHeight: 720)
                .preferredColorScheme(model.appearanceOverride)
                .task {
                    await model.start()
                    if let url = Self.openArgument { await model.openFromLaunch(url) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Go") {
                Button("Open URL…") { model.beginURLEdit() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Refresh") { Task { await model.refreshCurrent() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.currentServer == nil)
                Button("Deep crawl this server") { Task { await model.deepCrawlCurrentServer() } }
                    .disabled(model.currentServer == nil || model.deepCrawlStatus != nil)
            }
        }
    }
}
