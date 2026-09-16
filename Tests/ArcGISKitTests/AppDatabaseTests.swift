import XCTest
import Foundation
import ArcGISKit
import DuckDBKit

final class AppDatabaseTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var dbPath: String {
        scratch.appendingPathComponent("nested/explorer.duckdb").path
    }

    func testDefaultURLIsUnderApplicationSupport() {
        let url = AppDatabase.defaultURL()
        XCTAssertTrue(url.path.hasSuffix("/Library/Application Support/ArcGIS Explorer/explorer.duckdb"), url.path)
    }

    func testBundledMigrationsStartAtInitial() throws {
        let migrations = try AppDatabase.bundledMigrations()
        XCTAssertEqual(migrations.first?.version, 1)
        XCTAssertEqual(migrations.first?.name, "initial")
        XCTAssertEqual(migrations.map(\.version), Array(1...migrations.count), "versions must be contiguous")
    }

    func testOpenCreatesDirectoryMigratesAndHasSchema() async throws {
        let db = try AppDatabase(path: dbPath)
        let report = try await db.migrate()
        let bundled = try AppDatabase.bundledMigrations().map(\.version)
        XCTAssertEqual(report.applied, bundled)
        XCTAssertEqual(report.currentVersion, bundled.last)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))

        let expected = ["download", "download_chunk", "field", "layer", "query_history",
                        "schema_migrations", "server", "service", "setting"]
        let names = try await db.tableNames()
        XCTAssertEqual(names, expected)
    }

    func testMigrateAgainIsANoopAndPersists() async throws {
        do {
            let db = try AppDatabase(path: dbPath)
            try await db.migrate()
            try await db.query("INSERT INTO setting (key, value) VALUES ('download_dir', '/tmp/x');")
        }
        let reopened = try AppDatabase(path: dbPath)
        let report = try await reopened.migrate()
        let latest = try AppDatabase.bundledMigrations().last?.version ?? 0
        XCTAssertEqual(report, MigrationReport(applied: [], currentVersion: latest))
        let value = try await reopened.query("SELECT value FROM setting WHERE key = 'download_dir';").scalarString
        XCTAssertEqual(value, "/tmp/x")
    }

    /// Sequences and defaults in the initial schema behave: ids allocate, uniqueness holds,
    /// and the DDL that the crawler will rely on actually exists.
    func testSchemaDefaultsAndConstraints() async throws {
        let db = try AppDatabase(path: dbPath)
        try await db.migrate()
        try await db.query("""
            INSERT INTO server (id, root_url, friendly_name, created_at)
            VALUES (nextval('seq_server'), 'https://example.com/arcgis/rest/services', 'Example', CAST(now() AS TIMESTAMP));
            """)
        let row = try await db.query("SELECT id, auth_kind, origin_override FROM server;").rows[0]
        XCTAssertEqual(row, [.int(1), .string("none"), .null])

        await XCTAssertThrowsErrorAsync(
            try await db.query("""
                INSERT INTO server (id, root_url, friendly_name, created_at)
                VALUES (nextval('seq_server'), 'https://example.com/arcgis/rest/services', 'Dup', CAST(now() AS TIMESTAMP));
                """)) { error in
            XCTAssertTrue(String(describing: error).lowercased().contains("constraint"), String(describing: error))
        }

        try await db.query("""
            INSERT INTO service (id, server_id, name, type, url)
            VALUES (nextval('seq_service'), 1, 'Roads', 'FeatureServer', 'https://example.com/arcgis/rest/services/Roads/FeatureServer');
            """)
        try await db.query("""
            INSERT INTO layer (id, service_id, layer_id, name) VALUES (nextval('seq_layer'), 1, 0, 'Centrelines');
            """)
        try await db.query("""
            INSERT INTO field (id, layer_id, position, name, esri_type, duck_type)
            VALUES (nextval('seq_field'), 1, 0, 'OBJECTID', 'esriFieldTypeOID', 'BIGINT'),
                   (nextval('seq_field'), 1, 1, 'UPRN', 'esriFieldTypeString', 'VARCHAR');
            """)
        let hits = try await db.query("SELECT name FROM field WHERE name ILIKE '%uprn%';")
        XCTAssertEqual(hits.rows, [[.string("UPRN")]])
    }
}

/// XCTest has no async `XCTAssertThrowsError`; this is the minimal equivalent.
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath, line: UInt = #line,
    _ handler: (Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        handler(error)
    }
}
