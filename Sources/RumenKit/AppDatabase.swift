import Foundation
import SQLiteKit
import DuckDBKit

/// The single app database: cached ArcGIS metadata and download bookkeeping (SPEC §7.2), in
/// SQLite. Downloaded data never lives here — see `SPEC.md` §5.7.
///
/// Owns one SQLite connection behind an actor so all access is serialised and off the main
/// thread, plus an in-memory DuckDB with the spatial extension for extent reprojection.
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
    /// (if needed) and loaded. Needed for WGS 84 extents; the download engine opens its own
    /// staging connections.
    public func loadSpatial() throws {
        let engine = try DuckDB()
        try engine.run("INSTALL spatial;")
        try engine.run("LOAD spatial;")
        spatial = engine
    }

    public var isSpatialLoaded: Bool { spatial != nil }

    /// Reprojects a native-SR extent to a WGS 84 box for the extent locators. Returns nil —
    /// deliberately, not as an error — when the extent is empty or PROJ does not know the
    /// spatial reference: the locator then draws no box, which is the honest display.
    /// Throws if the spatial engine has not been loaded.
    public func wgs84Extent(of extent: Extent?, wkid: Int?) throws -> BoundingBox? {
        guard let spatial else { throw SpatialError.notLoaded }
        guard let e = extent, let xmin = e.xmin, let ymin = e.ymin, let xmax = e.xmax, let ymax = e.ymax,
              let wkid = wkid ?? e.spatialReference?.effectiveWkid else { return nil }
        // Seen on ArcGIS Online: an extent in degrees tagged Web Mercator. Metre coordinates that
        // all fit inside lon/lat range would be a few hundred metres around Null Island, which no
        // real layer is, so such a box is read as degrees. Only for the Mercator family: an
        // unknown CRS must still come back as unknown.
        let webMercator: Set<Int> = [3857, 102100, 102113, 900913, 3785]
        let looksLikeDegrees = webMercator.contains(wkid)
            && abs(xmin) <= 180 && abs(xmax) <= 180 && abs(ymin) <= 90 && abs(ymax) <= 90
        if wkid == 4326 || looksLikeDegrees {
            return BoundingBox(minX: xmin, minY: ymin, maxX: xmax, maxY: ymax).clampedToWorld
        }
        let sql = """
            WITH g AS (
                SELECT ST_Transform(ST_MakeEnvelope(?, ?, ?, ?), ?, 'EPSG:4326', always_xy := true) AS geom
            )
            SELECT ST_XMin(geom), ST_YMin(geom), ST_XMax(geom), ST_YMax(geom) FROM g;
            """
        let rows: [[DuckValue]]
        do {
            rows = try spatial.run(sql, [.double(xmin), .double(ymin), .double(xmax), .double(ymax),
                                         .string("EPSG:\(wkid)")]).rows
        } catch {
            return nil   // unknown CRS to PROJ — no box, by design (see doc comment)
        }
        guard let r = rows.first, r.count == 4, let a = r[0].doubleValue, let b = r[1].doubleValue,
              let c = r[2].doubleValue, let d = r[3].doubleValue, a.isFinite, b.isFinite, c.isFinite, d.isFinite
        else { return nil }
        return BoundingBox(minX: a, minY: b, maxX: c, maxY: d).clampedToWorld
    }
}
