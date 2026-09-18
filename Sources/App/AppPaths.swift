import Foundation
import RumenKit

/// Where this process keeps its state. By default that is the per-user Application Support
/// folder and `~/Documents/Rumen` for downloads. `--home <dir>` moves the database,
/// the staging folder and the default download folder under one directory, so the UI tests
/// and scripted captures run against a scratch copy and never touch the real one. The DuckDB
/// extension folder stays per user: it is a cache, and refetching `spatial` per run is waste.
enum AppPaths {
    static let home: URL = {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--home"), index + 1 < args.count {
            return URL(fileURLWithPath: args[index + 1], isDirectory: true)
        }
        return AppDatabase.defaultURL().deletingLastPathComponent()
    }()

    /// True when `--home` moved everything under a scratch directory.
    static var isScratch: Bool { CommandLine.arguments.contains("--home") }

    static var database: URL { home.appendingPathComponent("explorer.sqlite") }
    static var staging: URL { home.appendingPathComponent("staging", isDirectory: true) }

    /// The download folder before the user picks one.
    static var defaultDownloads: URL {
        if isScratch { return home.appendingPathComponent("Downloads", isDirectory: true) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Rumen", isDirectory: true)
    }
}
