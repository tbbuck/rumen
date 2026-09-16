import XCTest
import DuckDBKit

final class PreparedTests: XCTestCase {

    func testBindsEveryValueKind() throws {
        let db = try DuckDB()
        try db.run("CREATE TABLE p (b BOOLEAN, i BIGINT, d DOUBLE, s VARCHAR, bl BLOB, ts TIMESTAMP, dt DATE, n INTEGER);")
        try db.run("INSERT INTO p VALUES (?, ?, ?, ?, ?, ?, ?, ?);", [
            .bool(true), .int(-7), .double(2.5), .string("it's"), .blob([1, 2]),
            .timestamp(micros: 1_767_600_900_000_000), .date(days: 20_458), .null,
        ])
        let row = try db.run("SELECT * FROM p;").rows[0]
        XCTAssertEqual(row, [.bool(true), .int(-7), .double(2.5), .string("it's"), .blob([1, 2]),
                             .string("2026-01-05 08:15:00"), .string("2026-01-05"), .null])
    }

    func testParametersInSelectAndReturning() throws {
        let db = try DuckDB()
        try db.run("CREATE SEQUENCE s; CREATE TABLE t (id BIGINT DEFAULT nextval('s'), name VARCHAR UNIQUE);")
        let inserted = try db.run("INSERT INTO t (name) VALUES (?) RETURNING id;", [.string("a")])
        XCTAssertEqual(inserted.rows, [[.int(1)]])
        let found = try db.run("SELECT id FROM t WHERE name = ?;", [.string("a")])
        XCTAssertEqual(found.rows, [[.int(1)]])
        let upsert = try db.run("""
            INSERT INTO t (name) VALUES (?) ON CONFLICT (name) DO UPDATE SET name = excluded.name RETURNING id;
            """, [.string("a")])
        XCTAssertEqual(upsert.rows, [[.int(1)]], "conflict keeps the existing id")
    }

    func testParameterCountMismatchIsAnError() throws {
        let db = try DuckDB()
        XCTAssertThrowsError(try db.run("SELECT ?, ?;", [.int(1)])) { error in
            XCTAssertTrue(String(describing: error).contains("2 parameters but 1"), String(describing: error))
        }
    }

    func testPrepareAndExecuteErrorsCarryEngineMessage() throws {
        let db = try DuckDB();
        XCTAssertThrowsError(try db.run("SELEC ?;", [.int(1)])) { error in
            XCTAssertTrue(String(describing: error).lowercased().contains("syntax"), String(describing: error))
        }
        XCTAssertThrowsError(try db.run("SELECT * FROM nope WHERE x = ?;", [.int(1)])) { error in
            XCTAssertTrue(String(describing: error).contains("nope"), String(describing: error))
        }
    }

    func testOptionalHelpers() {
        XCTAssertEqual(BindValue.optional(nil as String?), .null)
        XCTAssertEqual(BindValue.optional("x"), .string("x"))
        XCTAssertEqual(BindValue.optional(3 as Int?), .int(3))
        XCTAssertEqual(BindValue.optional(true as Bool?), .bool(true))
        XCTAssertEqual(BindValue.optional(nil as Double?), .null)
    }
}
