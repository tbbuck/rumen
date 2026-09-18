import XCTest
import Foundation
import DuckDBKit

/// Engine wrapper tests: the Swift wrapper drives the locally-linked libduckdb, decodes typed
/// values from native data chunks, surfaces errors verbatim, and loads `spatial`.
final class DuckDBTests: XCTestCase {

    func testLibraryVersionIsReported() {
        XCTAssertTrue(DuckDB.libraryVersion.hasPrefix("v"), DuckDB.libraryVersion)
    }

    func testScalarTypeDecoding() throws {
        let db = try DuckDB()
        let r = try db.run("""
            SELECT
                TRUE                                   AS b,
                CAST(-42 AS INTEGER)                   AS i,
                CAST(18446744073709551615 AS UBIGINT)  AS u,
                CAST(3.5 AS DOUBLE)                    AS d,
                'hi'                                   AS s,
                CAST(123456789012345678901234 AS HUGEINT) AS h,
                CAST(1234.56 AS DECIMAL(10,2))         AS dec,
                DATE '2026-01-05'                      AS dt,
                TIMESTAMP '2026-01-05 08:15:00'        AS ts,
                NULL::INTEGER                          AS n;
            """)
        XCTAssertEqual(r.rows[0][0], .bool(true))
        XCTAssertEqual(r.rows[0][1], .int(-42))
        XCTAssertEqual(r.rows[0][2], .uint(UInt64.max))
        XCTAssertEqual(r.rows[0][3], .double(3.5))
        XCTAssertEqual(r.rows[0][4], .string("hi"))
        XCTAssertEqual(r.rows[0][5], .string("123456789012345678901234"))
        XCTAssertEqual(r.rows[0][6], .string("1234.56"))
        XCTAssertEqual(r.rows[0][7], .string("2026-01-05"))
        XCTAssertEqual(r.rows[0][8], .string("2026-01-05 08:15:00"))
        XCTAssertEqual(r.rows[0][9], .null)
    }

    /// A result spanning multiple data chunks (>2048 rows) must decode fully.
    func testMultiChunkResult() throws {
        let db = try DuckDB()
        let r = try db.run("SELECT i FROM range(5000) t(i);")
        XCTAssertEqual(r.rowCount, 5000)
        XCTAssertEqual(r.rows.first, [.int(0)])
        XCTAssertEqual(r.rows.last, [.int(4999)])
    }

    func testMaxRowsCaps() throws {
        let db = try DuckDB()
        let r = try db.run("SELECT i FROM range(5000) t(i);", maxRows: 10)
        XCTAssertEqual(r.rowCount, 10)
    }

    func testErrorsAreSurfacedNotSwallowed() throws {
        let db = try DuckDB()
        XCTAssertThrowsError(try db.run("SELECT * FROM table_that_does_not_exist;")) { error in
            XCTAssertTrue(String(describing: error).contains("table_that_does_not_exist"))
        }
    }

    func testOpensWithStartupConfig() throws {
        let db = try DuckDB(config: DuckDBConfig(allowUnsignedExtensions: true, disableAutoinstall: true))
        XCTAssertEqual(try db.run("SELECT current_setting('allow_unsigned_extensions');").scalarString, "true")
        XCTAssertEqual(try db.run("SELECT current_setting('autoinstall_known_extensions');").scalarString, "false")
    }

    /// `spatial` is the one extension this app needs (staging, export, map). INSTALL first so a
    /// clean machine (CI) bootstraps it; a no-op once cached under the extension directory.
    func testSpatialLoadsAndRoundTripsGeometry() throws {
        let db = try DuckDB()
        try db.run("INSTALL spatial;")
        try db.run("LOAD spatial;")
        XCTAssertEqual(try db.run("SELECT ST_AsText(ST_Point(1, 2));").scalarString, "POINT (1 2)")
        let typed = try db.run("SELECT ST_Point(1, 2) AS g;")
        XCTAssertEqual(typed.columns.first?.type, .geometry)
    }

    /// A file-backed database persists across opens.
    func testFileDatabasePersists() throws {
        let path = NSTemporaryDirectory() + "rumen-\(UUID().uuidString).duckdb"
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let db = try DuckDB(path: path)
            try db.run("CREATE TABLE t AS SELECT 7 AS x;")
        }
        let reopened = try DuckDB(path: path)
        XCTAssertEqual(try reopened.run("SELECT x FROM t;").scalarString, "7")
    }
}
