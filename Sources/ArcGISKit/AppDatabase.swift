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
    private var spatialLoaded = false

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
        let report = try Migrator.apply(try Self.bundledMigrations(), to: db)
        // Flush DDL to the main file: a WAL that still holds it is fragile on replay.
        try db.run("CHECKPOINT;")
        return report
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

    /// Runs one parameterised statement (`?` placeholders, bound in order).
    @discardableResult
    public func query(_ sql: String, _ params: [BindValue], maxRows: Int? = nil) throws -> QueryResult {
        try Task.checkCancellation()
        return try db.run(sql, params, maxRows: maxRows)
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

// MARK: - Spatial

public enum SpatialError: Error, CustomStringConvertible, Equatable {
    case notLoaded
    public var description: String { "the spatial extension is not loaded on the app database" }
}

extension AppDatabase {
    /// Installs (if needed) and loads DuckDB's `spatial` extension on this connection. Needed
    /// for WGS 84 extents; the download engine loads it on its own staging connections.
    public func loadSpatial() throws {
        try db.run("INSTALL spatial;")
        try db.run("LOAD spatial;")
        spatialLoaded = true
    }

    public var isSpatialLoaded: Bool { spatialLoaded }

    /// Reprojects a native-SR extent to a WGS 84 box for the extent locators. Returns nil —
    /// deliberately, not as an error — when the extent is empty or PROJ does not know the
    /// spatial reference: the locator then draws no box, which is the honest display.
    /// Throws if `spatial` has not been loaded.
    public func wgs84Extent(of extent: Extent?, wkid: Int?) throws -> BoundingBox? {
        guard spatialLoaded else { throw SpatialError.notLoaded }
        guard let e = extent, let xmin = e.xmin, let ymin = e.ymin, let xmax = e.xmax, let ymax = e.ymax,
              let wkid = wkid ?? e.spatialReference?.effectiveWkid else { return nil }
        if wkid == 4326 {
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
            rows = try db.run(sql, [.double(xmin), .double(ymin), .double(xmax), .double(ymax),
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
