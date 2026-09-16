import XCTest
import Foundation
import SQLiteKit

final class SQLiteTests: XCTestCase {

    func testLibraryVersion() {
        XCTAssertTrue(SQLiteKit.SQLite.libraryVersion.hasPrefix("3."), SQLiteKit.SQLite.libraryVersion)
    }

    func testBindsAndReadsEveryStorageClass() throws {
        let db = try SQLite(path: ":memory:")
        try db.execScript("CREATE TABLE t (b INTEGER, i INTEGER, d REAL, s TEXT, bl BLOB, ts INTEGER, n INTEGER, e BLOB);")
        try db.run("INSERT INTO t VALUES (?, ?, ?, ?, ?, ?, ?, ?);",
                   [.bool(true), .int(-7), .double(2.5), .string("it's ünïcode"), .blob([1, 2, 3]),
                    .timestamp(micros: 1_767_600_900_000_000), .null, .blob([])])
        let r = try db.run("SELECT * FROM t;")
        XCTAssertEqual(r.columns, ["b", "i", "d", "s", "bl", "ts", "n", "e"])
        XCTAssertEqual(r.rows, [[.int(1), .int(-7), .double(2.5), .text("it's ünïcode"), .blob([1, 2, 3]),
                                 .int(1_767_600_900_000_000), .null, .blob([])]])
        XCTAssertEqual(r.rows[0][0].boolValue, true)
        XCTAssertEqual(r.rows[0][5].dateFromMicros, Date(timeIntervalSince1970: 1_767_600_900))
        XCTAssertEqual(r.rows[0][1].doubleValue, -7)
        XCTAssertEqual(try db.run("SELECT count(*) FROM t;").scalarString, "1")
    }

    func testReturningAndUpsert() throws {
        let db = try SQLite(path: ":memory:")
        try db.execScript("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE, n INTEGER DEFAULT 0);")
        XCTAssertEqual(try db.run("INSERT INTO t (name) VALUES (?) RETURNING id;", [.string("a")]).rows, [[.int(1)]])
        XCTAssertEqual(db.lastInsertRowID, 1)
        let upsert = try db.run("""
            INSERT INTO t (name, n) VALUES (?, 1) ON CONFLICT (name) DO UPDATE SET n = n + 1 RETURNING id, n;
            """, [.string("a")])
        XCTAssertEqual(upsert.rows, [[.int(1), .int(1)]], "conflict keeps the id and returns the updated row")
        // AUTOINCREMENT burns an id on the conflicting insert, so the next fresh row is 3, not 2.
        let next = try db.run("INSERT INTO t (name) VALUES (?) RETURNING id;", [.string("b")]).rows[0][0].int64
        XCTAssertGreaterThan(next!, 1)
    }

    func testErrorsCarrySQLiteMessage() throws {
        let db = try SQLite(path: ":memory:")
        XCTAssertThrowsError(try db.run("SELEC 1;")) { error in
            XCTAssertTrue(String(describing: error).contains("syntax error"), String(describing: error))
        }
        XCTAssertThrowsError(try db.run("SELECT * FROM nope;")) { error in
            XCTAssertTrue(String(describing: error).contains("no such table: nope"), String(describing: error))
        }
        XCTAssertThrowsError(try db.run("SELECT ?, ?;", [.int(1)])) { error in
            XCTAssertEqual(error as? SQLiteError, .parameterCount(sql: "SELECT ?, ?;", expected: 2, got: 1))
        }
        XCTAssertThrowsError(try db.run("SELECT 1; SELECT 2;")) { error in
            XCTAssertTrue(String(describing: error).contains("one statement"), String(describing: error))
        }
        XCTAssertThrowsError(try db.execScript("CREATE TABLE x (a); CREATE TABLE x (a);")) { error in
            XCTAssertTrue(String(describing: error).contains("already exists"), String(describing: error))
        }
    }

    func testFileDatabaseUsesWALAndPersists() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.sqlite").path
        do {
            let db = try SQLite(path: path)
            XCTAssertEqual(try db.run("PRAGMA journal_mode;").scalarString, "wal")
            XCTAssertEqual(try db.run("PRAGMA foreign_keys;").scalarString, "1")
            try db.execScript("CREATE TABLE t (x INTEGER); INSERT INTO t VALUES (7);")
        }
        let reopened = try SQLite(path: path)
        XCTAssertEqual(try reopened.run("SELECT x FROM t;").scalarString, "7")
    }

    func testTransactionsRollBack() throws {
        let db = try SQLite(path: ":memory:")
        try db.execScript("CREATE TABLE t (x INTEGER UNIQUE);")
        try db.execScript("BEGIN;")
        try db.run("INSERT INTO t VALUES (1);")
        try db.execScript("ROLLBACK;")
        XCTAssertEqual(try db.run("SELECT count(*) FROM t;").scalarString, "0")
    }
}
