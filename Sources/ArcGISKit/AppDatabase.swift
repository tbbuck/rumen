import Foundation
import DuckDBKit

/// The single app database: cached ArcGIS metadata and download bookkeeping (SPEC §7.2).
/// Downloaded data never lives here — see `SPEC.md` §5.7.
///
/// Owns one DuckDB connection behind an actor so all access is serialised and off the main
/// thread. Open it, then call `migrate()` before anything else.
public actor AppDatabase {
    private nonisolated let db: DuckDB
    public let path: String

    /// `~/Library/Application Support/ArcGIS Explorer/explorer.duckdb`.
    public static func defaultURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("ArcGIS Explorer", isDirectory: true)
            .appendingPathComponent("explorer.duckdb")
    }

    /// Opens (creating if needed) the database file at `path`, creating its directory first.
    public init(path: String, config: DuckDBConfig = .init()) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.path = path
        self.db = try DuckDB(path: path, config: config)
    }

    /// Applies any pending bundled migrations. Safe to call on every launch.
    @discardableResult
    public func migrate() throws -> MigrationReport {
        try Migrator.apply(try Self.bundledMigrations(), to: db)
    }

    /// The migrations shipped in this build's resource bundle, sorted by version.
    public static func bundledMigrations() throws -> [Migration] {
        guard let directory = Bundle.module.url(forResource: "Migrations", withExtension: nil) else {
            throw MigrationError.badFilename("Migrations directory missing from the ArcGISKit bundle")
        }
        return try Migrator.load(directory: directory)
    }

    /// Runs one statement. Throws `CancellationError` without touching the engine if the
    /// calling task was already cancelled.
    @discardableResult
    public func query(_ sql: String, maxRows: Int? = nil) throws -> QueryResult {
        try Task.checkCancellation()
        return try db.run(sql, maxRows: maxRows)
    }

    /// Names of the user tables currently in the database, sorted.
    public func tableNames() throws -> [String] {
        let result = try db.run("""
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'main' AND table_type = 'BASE TABLE'
            ORDER BY table_name;
            """)
        return result.rows.compactMap { $0.first?.stringValue }
    }

    public nonisolated var engineVersion: String { DuckDB.libraryVersion }
}
