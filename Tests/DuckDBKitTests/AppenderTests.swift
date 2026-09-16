import XCTest
import DuckDBKit

/// The Appender is the download engine's write path into staging tables (SPEC §5.6):
/// typed rows in, queryable table out, engine errors surfaced.
final class AppenderTests: XCTestCase {

    private func database() throws -> DuckDB {
        let db = try DuckDB()
        try db.run("""
            CREATE TABLE t (
                id INTEGER, name VARCHAR, score DOUBLE, ok BOOLEAN,
                payload BLOB, ts TIMESTAMP, d DATE
            );
            """)
        return db
    }

    func testAppendsTypedRowsAndCloses() throws {
        let db = try database()
        let appender = try db.appender(table: "t")
        XCTAssertEqual(appender.columnCount, 7)

        try appender.append(Int32(1))
        try appender.appendString("alpha")
        try appender.append(1.5)
        try appender.append(true)
        try appender.appendBlob([0xDE, 0xAD])
        try appender.appendTimestamp(micros: 1_767_600_900_000_000)   // 2026-01-05 08:15:00 UTC
        try appender.appendDate(days: 20_458)                           // 2026-01-05
        try appender.endRow()

        try appender.append(Int32(2))
        try appender.appendNull()
        try appender.appendNull()
        try appender.append(false)
        try appender.appendNull()
        try appender.appendNull()
        try appender.appendNull()
        try appender.endRow()
        try appender.close()

        XCTAssertEqual(try db.run("SELECT count(*) FROM t;").scalarString, "2")
        let first = try db.run("SELECT * FROM t WHERE id = 1;").rows[0]
        XCTAssertEqual(first, [.int(1), .string("alpha"), .double(1.5), .bool(true),
                               .blob([0xDE, 0xAD]), .string("2026-01-05 08:15:00"), .string("2026-01-05")])
        let second = try db.run("SELECT name, score, payload FROM t WHERE id = 2;").rows[0]
        XCTAssertEqual(second, [.null, .null, .null])
    }

    func testAppendsDuckValues() throws {
        let db = try DuckDB()
        try db.run("CREATE TABLE v (i BIGINT, u UBIGINT, s VARCHAR, b BLOB, n INTEGER);")
        let appender = try db.appender(table: "v")
        for value in [DuckValue.int(-5), .uint(UInt64.max), .string("x'y"), .blob([1, 2, 3]), .null] {
            try appender.append(value)
        }
        try appender.endRow()
        try appender.close()
        XCTAssertEqual(try db.run("SELECT * FROM v;").rows[0],
                       [.int(-5), .uint(UInt64.max), .string("x'y"), .blob([1, 2, 3]), .null])
    }

    /// Rows appended and flushed (not yet closed) are visible to queries on the connection.
    func testFlushMakesRowsVisible() throws {
        let db = try DuckDB()
        try db.run("CREATE TABLE f (x INTEGER);")
        let appender = try db.appender(table: "f")
        for i in 0..<5000 {
            try appender.append(Int32(i))
            try appender.endRow()
        }
        try appender.flush()
        XCTAssertEqual(try db.run("SELECT count(*) FROM f;").scalarString, "5000")
        try appender.close()
    }

    func testMissingTableIsAnError() throws {
        let db = try DuckDB()
        XCTAssertThrowsError(try db.appender(table: "nope")) { error in
            guard case DuckError.appender(let message) = error else {
                return XCTFail("expected DuckError.appender, got \(error)")
            }
            XCTAssertTrue(message.contains("nope"), message)
        }
    }

    func testShortRowIsAnError() throws {
        let db = try DuckDB()
        try db.run("CREATE TABLE two (a INTEGER, b INTEGER);")
        let appender = try db.appender(table: "two")
        try appender.append(Int32(1))
        XCTAssertThrowsError(try appender.endRow()) { error in
            guard case DuckError.appender(let message) = error else {
                return XCTFail("expected DuckError.appender, got \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// The staging design: geometry arrives as WKB in a BLOB column and is turned into a
    /// GEOMETRY at export time with the spatial extension.
    func testWKBBlobBecomesGeometryAtExport() throws {
        let db = try DuckDB()
        try db.run("INSTALL spatial;")
        try db.run("LOAD spatial;")
        try db.run("CREATE TABLE staging (oid BIGINT, geom_wkb BLOB);")
        let appender = try db.appender(table: "staging")
        // WKB, little-endian: POINT (1 2)
        let wkb: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x00,
                            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF0, 0x3F,
                            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x40]
        try appender.append(Int64(1))
        try appender.appendBlob(wkb)
        try appender.endRow()
        try appender.close()
        XCTAssertEqual(
            try db.run("SELECT ST_AsText(ST_GeomFromWKB(geom_wkb)) FROM staging;").scalarString,
            "POINT (1 2)")
    }
}
