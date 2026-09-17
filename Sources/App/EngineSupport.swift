import Foundation
import DuckDBKit

/// Where the packaged app keeps DuckDB's `spatial` extension, and how it configures the engine
/// (M9, as in DuckLake Explorer).
///
/// The `.duckdb_extension` file cannot be bundled: its metadata and signature footer is not
/// notarizable, and DuckDB confirms signing dynamically loaded extensions is not currently
/// possible (duckdb/duckdb#16926). So a packaged build points `extension_directory` at a
/// per-user Application Support folder and lets `INSTALL spatial` fetch it there on first use,
/// loaded under the disable-library-validation entitlement. Dev and unbundled builds return
/// nil and use the engine's default `~/.duckdb`, which already has it.
enum EngineSupport {
    /// A writable per-user extension directory for the packaged app; nil in dev builds.
    /// "Packaged" means the app ships its own `libduckdb` in `Contents/Frameworks`.
    static func extensionDirectory() throws -> String? {
        let bundledLibrary = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libduckdb.dylib")
        guard FileManager.default.fileExists(atPath: bundledLibrary.path) else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("ArcGIS Explorer/duckdb-extensions", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.path
    }

    /// Sets the engine's default configuration for this process. Call once, before any
    /// DuckDB opens: the spatial engine, staging databases, re-exports, and stored files all
    /// pick it up. Autoinstall and DuckDB's own signature check stay on; the fetched extension
    /// is DuckDB-signed, so nothing loads unsigned.
    static func install() throws {
        if let directory = try extensionDirectory() {
            DuckDB.defaultConfig = DuckDBConfig(extensionDirectory: directory)
        }
    }
}

/// Headless smoke test for the packaged app (`--selftest`): configures the engine exactly as the
/// app does, installs and loads `spatial` (fetching it into the per-user folder on a clean
/// Mac), and reprojects one point through the CRS registry, then exits. Run the signed binary
/// directly so library validation is enforced:
///
///   "ArcGIS Explorer.app/Contents/MacOS/ArcGIS Explorer" --selftest
///
/// Exits 0 on success, 1 on failure, with the engine's own message on stderr.
enum SelfTest {
    static func run() -> Never {
        do {
            try EngineSupport.install()
            let directory = try EngineSupport.extensionDirectory()
            let engine = try DuckDB()
            try engine.run("INSTALL spatial;")
            try engine.run("LOAD spatial;")
            let row = try engine.run("""
                SELECT round(ST_X(g)), round(ST_Y(g))
                FROM (SELECT ST_Transform(ST_Point(-0.1276, 51.5074), 'EPSG:4326', 'EPSG:27700', always_xy := true) AS g);
                """).rows.first ?? []
            let x = row.first?.doubleValue ?? 0
            let y = row.count > 1 ? row[1].doubleValue ?? 0 : 0
            guard abs(x - 530_000) < 2_000, abs(y - 180_000) < 2_000 else {
                throw SelfTestError.wrongAnswer("London reprojected to \(x), \(y); expected about 530000, 180000")
            }
            print("selftest OK — extensions from \(directory ?? "system (~/.duckdb)"); London in BNG = \(Int(x)), \(Int(y))")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("selftest FAIL — \(error)\n".utf8))
            exit(1)
        }
    }

    enum SelfTestError: Error, CustomStringConvertible {
        case wrongAnswer(String)
        var description: String { switch self { case .wrongAnswer(let s): return s } }
    }
}
