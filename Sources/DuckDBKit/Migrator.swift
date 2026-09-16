import Foundation

/// One numbered SQL migration, parsed from a file named `NNNN_description.sql`.
public struct Migration: Sendable, Equatable {
    public let version: Int
    public let name: String
    public let sql: String

    public init(version: Int, name: String, sql: String) {
        self.version = version
        self.name = name
        self.sql = sql
    }

    /// Parses `0001_initial.sql` → version 1, name "initial". Any other shape is an error;
    /// migrations are ours, so a bad filename is a bug, not a condition to tolerate.
    public static func parse(filename: String, sql: String) throws -> Migration {
        let stem = filename.hasSuffix(".sql") ? String(filename.dropLast(4)) : filename
        guard filename.hasSuffix(".sql"),
              let underscore = stem.firstIndex(of: "_"),
              let version = Int(stem[..<underscore]),
              version > 0,
              stem.index(after: underscore) < stem.endIndex
        else { throw MigrationError.badFilename(filename) }
        return Migration(version: version, name: String(stem[stem.index(after: underscore)...]), sql: sql)
    }
}

public enum MigrationError: Error, CustomStringConvertible, Equatable {
    case badFilename(String)
    case duplicateVersion(Int)
    /// The database records a version this build does not ship — an older build opening a
    /// newer database. Refuse rather than guess.
    case unknownAppliedVersion(Int)
    /// A pending migration is older than one already applied: the ordering was violated.
    case outOfOrder(pending: Int, latestApplied: Int)
    case failed(version: Int, message: String)

    public var description: String {
        switch self {
        case .badFilename(let f):
            return "migration filename '\(f)' is not of the form NNNN_name.sql"
        case .duplicateVersion(let v):
            return "two migrations share version \(v)"
        case .unknownAppliedVersion(let v):
            return "database has migration \(v) applied but this build does not include it"
        case .outOfOrder(let pending, let latest):
            return "migration \(pending) is pending but \(latest) is already applied"
        case .failed(let v, let m):
            return "migration \(v) failed: \(m)"
        }
    }
}

/// What a `Migrator.apply` run did.
public struct MigrationReport: Sendable, Equatable {
    /// Versions applied by this run, in order. Empty when the database was already current.
    public let applied: [Int]
    /// Highest version now recorded in the database (0 for a database with no migrations).
    public let currentVersion: Int

    public init(applied: [Int], currentVersion: Int) {
        self.applied = applied
        self.currentVersion = currentVersion
    }
}

/// Applies numbered SQL migrations to a DuckDB database, recording each in
/// `schema_migrations`. Every migration runs in its own transaction: a failure rolls it back,
/// leaves the version unrecorded, and is thrown with the engine's message.
public enum Migrator {
    /// Loads migrations from `.sql` files in `directory`, sorted by version.
    public static func load(directory: URL) throws -> [Migration] {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
        return try load(files: files.filter { $0.pathExtension == "sql" })
    }

    /// Loads migrations from explicit file URLs, sorted by version.
    public static func load(files: [URL]) throws -> [Migration] {
        var migrations = [Migration]()
        for url in files {
            let sql = try String(contentsOf: url, encoding: .utf8)
            migrations.append(try Migration.parse(filename: url.lastPathComponent, sql: sql))
        }
        return try validated(migrations)
    }

    /// Sorts by version and rejects duplicates.
    public static func validated(_ migrations: [Migration]) throws -> [Migration] {
        let sorted = migrations.sorted { $0.version < $1.version }
        for (a, b) in zip(sorted, sorted.dropFirst()) where a.version == b.version {
            throw MigrationError.duplicateVersion(a.version)
        }
        return sorted
    }

    /// Applies every pending migration in version order.
    @discardableResult
    public static func apply(_ migrations: [Migration], to db: DuckDB) throws -> MigrationReport {
        let migrations = try validated(migrations)
        try db.run("""
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY,
                name VARCHAR NOT NULL,
                applied_at TIMESTAMP NOT NULL
            );
            """)
        let appliedRows = try db.run("SELECT version FROM schema_migrations ORDER BY version;")
        let applied = Set(appliedRows.rows.compactMap { $0.first?.int64 }.map(Int.init))
        let known = Set(migrations.map(\.version))
        if let unknown = applied.subtracting(known).min() {
            throw MigrationError.unknownAppliedVersion(unknown)
        }
        let latestApplied = applied.max() ?? 0

        var newlyApplied = [Int]()
        for migration in migrations where !applied.contains(migration.version) {
            if migration.version < latestApplied {
                throw MigrationError.outOfOrder(pending: migration.version, latestApplied: latestApplied)
            }
            try db.run("BEGIN TRANSACTION;")
            do {
                try db.run(migration.sql)
                try db.run("""
                    INSERT INTO schema_migrations (version, name, applied_at)
                    VALUES (\(migration.version), '\(escape(migration.name))', CAST(now() AS TIMESTAMP));
                    """)
                try db.run("COMMIT;")
            } catch {
                _ = try? db.run("ROLLBACK;")
                throw MigrationError.failed(version: migration.version, message: String(describing: error))
            }
            newlyApplied.append(migration.version)
        }
        return MigrationReport(applied: newlyApplied,
                               currentVersion: max(latestApplied, newlyApplied.last ?? 0))
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "'", with: "''")
    }
}
