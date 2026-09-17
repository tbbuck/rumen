import SwiftUI
import ArcGISKit
import SQLiteKit

/// Entry point. The window hides the system title bar so the path bar can be the spine
/// (UI-SPEC: "the URL is the spine"); `TitleBar` draws the 48px row behind the traffic lights.
@main
struct ArcGISExplorerApp: App {
    @State private var model = AppModel()

    /// `--open <url>`: navigate to an ArcGIS URL after launch (`open -a "ArcGIS Explorer" --args --open <url>`).
    static var openArgument: String? { argument("--open") }
    /// `--tab <name>`, `--run preview|download|export-geojson|export-csv`, `--stored <download id>`
    /// (open that download's layer on the Stored tab, from cache): for scripted window captures.
    static var tabArgument: String? { argument("--tab") }
    static var runArgument: String? { argument("--run") }
    static var searchArgument: String? { argument("--search") }
    static var storedArgument: Int64? { argument("--stored").flatMap(Int64.init) }

    private static func argument(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
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
                    if let id = Self.storedArgument { await model.showStoredDownload(id: id) }
                    if let tab = Self.tabArgument, let chosen = LayerTab(rawValue: tab.capitalizedFirst) { model.layerTab = chosen }
                    if Self.runArgument == "export-geojson" { await model.storedSession?.reexport(.geoJSON, overwrite: true) }
                    if Self.runArgument == "export-csv" { await model.storedSession?.reexport(.csv, overwrite: true) }
                    if Self.runArgument == "preview" { await model.querySession?.preview() }
                    if let text = Self.searchArgument { model.columnSearch = text }
                    if Self.runArgument == "download", let layer = model.currentLayer {
                        var request = DownloadRequest(layerID: layer.id, outputDirectory: model.downloadDirectory)
                        request.overwrite = true
                        await model.startDownload(request)
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Go") {
                Button("Start Page") { model.showStartPage() }
                    .keyboardShortcut("h", modifiers: [.command, .shift])
                Button("Open URL…") { model.beginURLEdit() }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Find column…") { model.focusColumnSearch = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Transfers") { model.showTransfers.toggle() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Button("Refresh") { Task { await model.refreshCurrent() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.currentServer == nil)
                Button("Deep crawl this server") { Task { await model.deepCrawlCurrentServer() } }
                    .disabled(model.currentServer == nil || model.deepCrawlStatus != nil)
            }
        }
    }
}
