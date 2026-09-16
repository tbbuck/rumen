import XCTest
import Foundation
import ArcGISKit
import DuckDBKit

/// An unclean exit (crash, force quit) leaves DuckDB replaying its write-ahead log on the next
/// open. The schema and the store's inserts must survive that: no function-call defaults in
/// the DDL, ids allocated in the INSERT. `disable_checkpoint_on_shutdown` forces the replay.
final class WALReplayTests: XCTestCase {

    func testSchemaAndRowsSurviveWALReplay() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("explorer.duckdb").path

        do {
            let db = try DuckDB(path: path)
            try db.run("PRAGMA disable_checkpoint_on_shutdown;")
            try Migrator.apply(try AppDatabase.bundledMigrations(), to: db)
            try db.run("""
                INSERT INTO server (id, root_url, friendly_name, created_at)
                VALUES (nextval('seq_server'), 'https://x.example/arcgis/rest/services', 'x', CAST(now() AS TIMESTAMP));
                """)
            try db.run("INSERT INTO setting (key, value) VALUES ('k', 'v');")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path + ".wal"), "the DDL and rows must be in the WAL for this test to mean anything")

        let reopened = try DuckDB(path: path)
        XCTAssertEqual(try reopened.run("SELECT count(*) FROM server;").scalarString, "1")
        XCTAssertEqual(try reopened.run("SELECT value FROM setting WHERE key = 'k';").scalarString, "v")
        XCTAssertEqual(try reopened.run("SELECT nextval('seq_server');").scalarString, "2", "sequence state replays too")
    }
}
