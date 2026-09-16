import XCTest
import Foundation
import DuckDBKit

final class MigratorTests: XCTestCase {

    private func tables(_ db: DuckDB) throws -> [String] {
        try db.run("""
            SELECT table_name FROM information_schema.tables
            WHERE table_schema = 'main' ORDER BY table_name;
            """).rows.compactMap { $0.first?.stringValue }
    }

    private func recorded(_ db: DuckDB) throws -> [Int] {
        try db.run("SELECT version FROM schema_migrations ORDER BY version;")
            .rows.compactMap { $0.first?.int64 }.map(Int.init)
    }

    // MARK: - Parsing

    func testParsesWellFormedFilenames() throws {
        let m = try Migration.parse(filename: "0001_initial.sql", sql: "SELECT 1;")
        XCTAssertEqual(m.version, 1)
        XCTAssertEqual(m.name, "initial")
        let n = try Migration.parse(filename: "0042_add_field_domain.sql", sql: "")
        XCTAssertEqual(n.version, 42)
        XCTAssertEqual(n.name, "add_field_domain")
    }

    func testRejectsMalformedFilenames() {
        for bad in ["initial.sql", "0001.sql", "0001_", "0001_x.txt", "abc_x.sql", "0000_zero.sql", "0001_x.sql.bak"] {
            XCTAssertThrowsError(try Migration.parse(filename: bad, sql: ""), bad) { error in
                XCTAssertEqual(error as? MigrationError, .badFilename(bad))
            }
        }
    }

    func testRejectsDuplicateVersions() {
        let a = Migration(version: 1, name: "a", sql: "")
        let b = Migration(version: 1, name: "b", sql: "")
        XCTAssertThrowsError(try Migrator.validated([a, b])) { error in
            XCTAssertEqual(error as? MigrationError, .duplicateVersion(1))
        }
    }

    func testLoadsFromDirectorySortedByVersion() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "CREATE TABLE b (x INTEGER);".write(to: dir.appendingPathComponent("0002_b.sql"), atomically: true, encoding: .utf8)
        try "CREATE TABLE a (x INTEGER);".write(to: dir.appendingPathComponent("0001_a.sql"), atomically: true, encoding: .utf8)
        try "not a migration".write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let loaded = try Migrator.load(directory: dir)
        XCTAssertEqual(loaded.map(\.version), [1, 2])
        XCTAssertEqual(loaded.map(\.name), ["a", "b"])
    }

    // MARK: - Applying

    func testAppliesInOrderAndRecords() throws {
        let db = try DuckDB()
        let report = try Migrator.apply([
            Migration(version: 2, name: "b", sql: "CREATE TABLE b (x INTEGER);"),
            Migration(version: 1, name: "a", sql: "CREATE TABLE a (x INTEGER);"),
        ], to: db)
        XCTAssertEqual(report, MigrationReport(applied: [1, 2], currentVersion: 2))
        XCTAssertEqual(try tables(db), ["a", "b", "schema_migrations"])
        XCTAssertEqual(try recorded(db), [1, 2])
        let names = try db.run("SELECT name FROM schema_migrations ORDER BY version;")
            .rows.compactMap { $0.first?.stringValue }
        XCTAssertEqual(names, ["a", "b"])
    }

    func testReapplyIsANoop() throws {
        let db = try DuckDB()
        let migrations = [Migration(version: 1, name: "a", sql: "CREATE TABLE a (x INTEGER);")]
        try Migrator.apply(migrations, to: db)
        let again = try Migrator.apply(migrations, to: db)
        XCTAssertEqual(again, MigrationReport(applied: [], currentVersion: 1))
        XCTAssertEqual(try recorded(db), [1])
    }

    func testMultiStatementMigrationRunsWhole() throws {
        let db = try DuckDB()
        try Migrator.apply([
            Migration(version: 1, name: "two", sql: """
                CREATE TABLE a (x INTEGER);
                -- a comment between statements
                CREATE TABLE b (y INTEGER);
                INSERT INTO b VALUES (1), (2);
                """),
        ], to: db)
        XCTAssertEqual(try tables(db), ["a", "b", "schema_migrations"])
        XCTAssertEqual(try db.run("SELECT count(*) FROM b;").scalarString, "2")
    }

    func testFailedMigrationRollsBackAndIsUnrecorded() throws {
        let db = try DuckDB()
        let migrations = [
            Migration(version: 1, name: "a", sql: "CREATE TABLE a (x INTEGER);"),
            Migration(version: 2, name: "broken", sql: """
                CREATE TABLE b (y INTEGER);
                SELECT * FROM does_not_exist;
                """),
        ]
        XCTAssertThrowsError(try Migrator.apply(migrations, to: db)) { error in
            guard case MigrationError.failed(let version, let message)? = error as? MigrationError else {
                return XCTFail("expected .failed, got \(error)")
            }
            XCTAssertEqual(version, 2)
            XCTAssertTrue(message.contains("does_not_exist"), message)
        }
        XCTAssertEqual(try tables(db), ["a", "schema_migrations"], "table b must have been rolled back")
        XCTAssertEqual(try recorded(db), [1])
    }

    func testUnknownAppliedVersionIsRefused() throws {
        let db = try DuckDB()
        try Migrator.apply([
            Migration(version: 1, name: "a", sql: "CREATE TABLE a (x INTEGER);"),
            Migration(version: 2, name: "b", sql: "CREATE TABLE b (x INTEGER);"),
        ], to: db)
        XCTAssertThrowsError(try Migrator.apply([
            Migration(version: 1, name: "a", sql: "CREATE TABLE a (x INTEGER);"),
        ], to: db)) { error in
            XCTAssertEqual(error as? MigrationError, .unknownAppliedVersion(2))
        }
    }

    func testOutOfOrderPendingIsRefused() throws {
        let db = try DuckDB()
        try Migrator.apply([Migration(version: 2, name: "b", sql: "CREATE TABLE b (x INTEGER);")], to: db)
        XCTAssertThrowsError(try Migrator.apply([
            Migration(version: 1, name: "a", sql: "CREATE TABLE a (x INTEGER);"),
            Migration(version: 2, name: "b", sql: "CREATE TABLE b (x INTEGER);"),
        ], to: db)) { error in
            XCTAssertEqual(error as? MigrationError, .outOfOrder(pending: 1, latestApplied: 2))
        }
    }
}
