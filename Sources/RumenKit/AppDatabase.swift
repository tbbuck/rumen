import Foundation
import SQLiteKit
import DuckDBKit

/// The single app database: cached ArcGIS metadata and download bookkeeping (SPEC §7.2), in
/// SQLite. Downloaded data never lives here — see `SPEC.md` §5.7.
///
/// Owns one SQLite connection behind an actor so all access is serialised and off the main
/// thread, plus an in-memory DuckDB with the spatial extension for reading stored downloads.
/// Open it, then call `migrate()` before anything else.
public actor AppDatabase {
    private nonisolated let db: SQLite
    public let path: String
    /// The spatial engine (an in-memory DuckDB with `spatial`), once `loadSpatial()` ran.
    var spatial: DuckDB?

    /// `~/Library/Application Support/Rumen`: the database, the staging folder, and the
    /// DuckDB extension cache.
    public static func supportDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Rumen", isDirectory: true)
    }

    public static let filename = "explorer.sqlite"

    /// `~/Library/Application Support/Rumen/explorer.sqlite`.
    public static func defaultURL() -> URL {
        supportDirectory().appendingPathComponent(filename)
    }

    /// The app was called ArcGIS Explorer until it grew its OGC half, and kept its state under
    /// that name. An install from then keeps its servers, its download history and its staged
    /// runs: the old folder's contents are carried across on the first launch that finds a
    /// database there and none here.
    ///
    /// The decision is keyed on the database file rather than on the folder, because the folder
    /// is not proof of an install — `--selftest` creates it just to hold the DuckDB extension
    /// cache, and a folder test would then strand the real database next door forever.
    ///
    /// Nothing is ever overwritten: an entry already present here is left alone and its old
    /// copy stays where it is, so the worst case is a stale cache left behind rather than lost
    /// state. A failure throws rather than falling through to a fresh database, which would
    /// look like the app had quietly forgotten every server.
    public static func adoptLegacySupportDirectory() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try adoptLegacySupportDirectory(under: support)
    }

    /// The move itself, against a given Application Support folder so the tests can use a
    /// temporary one.
    public static func adoptLegacySupportDirectory(under support: URL) throws {
        let fm = FileManager.default
        let legacy = support.appendingPathComponent("ArcGIS Explorer", isDirectory: true)
        let current = support.appendingPathComponent("Rumen", isDirectory: true)
        guard fm.fileExists(atPath: legacy.appendingPathComponent(filename).path) else { return }
        guard !fm.fileExists(atPath: current.appendingPathComponent(filename).path) else { return }

        try fm.createDirectory(at: current, withIntermediateDirectories: true)
        for entry in try fm.contentsOfDirectory(atPath: legacy.path) {
            let destination = current.appendingPathComponent(entry)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try fm.moveItem(at: legacy.appendingPathComponent(entry), to: destination)
        }
        if try fm.contentsOfDirectory(atPath: legacy.path).isEmpty {
            try fm.removeItem(at: legacy)
        }
    }

    /// Opens (creating if needed) the database file at `path`, creating its directory first.
    public init(path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.path = path
        self.db = try SQLite(path: path)
    }

    /// Applies any pending bundled migrations. Safe to call on every launch.
    @discardableResult
    public func migrate() throws -> MigrationReport {
        try Migrator.apply(try Self.bundledMigrations(), to: db)
    }

    /// The migrations shipped in this build's resource bundle, sorted by version.
    public static func bundledMigrations() throws -> [Migration] {
        guard let directory = Bundle.module.url(forResource: "Migrations", withExtension: nil) else {
            throw MigrationError.badFilename("Migrations directory missing from the RumenKit bundle")
        }
        return try Migrator.load(directory: directory)
    }

    /// Runs one statement. Throws `CancellationError` without touching the engine if the
    /// calling task was already cancelled.
    @discardableResult
    public func query(_ sql: String, _ params: [SQLBind] = []) throws -> SQLResult {
        try Task.checkCancellation()
        return try db.run(sql, params)
    }

    /// Runs a script of several statements (no parameters, no results).
    public func execScript(_ sql: String) throws {
        try Task.checkCancellation()
        try db.execScript(sql)
    }

    /// Names of the user tables currently in the database, sorted.
    public func tableNames() throws -> [String] {
        try db.run("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name;")
            .rows.compactMap { $0.first?.stringValue }
    }

    public nonisolated var engineVersion: String { "SQLite \(SQLite.libraryVersion)" }
}

// MARK: - Spatial

public enum SpatialError: Error, CustomStringConvertible, Equatable {
    case notLoaded
    public var description: String { "the spatial engine is not loaded" }
}

extension AppDatabase {
    /// Starts the spatial engine: an in-memory DuckDB with the `spatial` extension installed
    /// (if needed) and loaded. Needed to read stored downloads back for the map; the download
    /// engine opens its own staging connections.
    public func loadSpatial() throws {
        let engine = try DuckDB()
        try engine.run("INSTALL spatial;")
        try engine.run("LOAD spatial;")
        spatial = engine
    }

    public var isSpatialLoaded: Bool { spatial != nil }
}
