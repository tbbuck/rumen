import Foundation
import Observation
import ArcGISKit
import DuckDBKit

/// Single source of truth for the app, injected via `@Environment`. Main-actor bound; all
/// engine work happens on the `AppDatabase` actor.
@MainActor @Observable
final class AppModel {
    enum Phase: Equatable {
        case opening
        case ready
        case failed(String)
    }

    var phase: Phase = .opening
    let databasePath = AppDatabase.defaultURL().path
    var engineVersion = ""
    var schemaVersion = 0
    var migrationsAppliedThisLaunch: [Int] = []
    var tables: [String] = []
    private(set) var database: AppDatabase?

    /// Opens the app database and applies pending migrations. Any failure is surfaced
    /// verbatim in `phase` — there is nothing sensible to do with a broken app DB but tell.
    func start() async {
        do {
            let db = try AppDatabase(path: databasePath)
            let report = try await db.migrate()
            database = db
            engineVersion = db.engineVersion
            schemaVersion = report.currentVersion
            migrationsAppliedThisLaunch = report.applied
            tables = try await db.tableNames()
            phase = .ready
        } catch {
            phase = .failed(String(describing: error))
        }
    }
}
