import Foundation
import SQLite3

/// An error from SQLite, carrying its own message verbatim (never swallowed).
public enum SQLiteError: Error, CustomStringConvertible, Equatable {
    case open(path: String, message: String)
    case prepare(sql: String, message: String)
    case bind(sql: String, index: Int, message: String)
    case step(sql: String, message: String)
    case exec(message: String)
    case parameterCount(sql: String, expected: Int, got: Int)

    public var description: String {
        switch self {
        case .open(let p, let m): return "SQLite open failed for \(p): \(m)"
        case .prepare(let sql, let m): return "SQLite prepare failed: \(m)\n  SQL: \(sql)"
        case .bind(let sql, let i, let m): return "SQLite could not bind parameter \(i): \(m)\n  SQL: \(sql)"
        case .step(let sql, let m): return "SQLite statement failed: \(m)\n  SQL: \(sql)"
        case .exec(let m): return "SQLite script failed: \(m)"
        case .parameterCount(let sql, let e, let g): return "statement has \(e) parameters but \(g) were bound\n  SQL: \(sql)"
        }
    }
}

/// A cell read back from SQLite: its five storage classes.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob([UInt8])

    public var isNull: Bool { self == .null }
    public var int64: Int64? { if case .int(let i) = self { return i }; return nil }
    public var intValue: Int? { int64.map(Int.init) }
    public var stringValue: String? { if case .text(let s) = self { return s }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    /// SQLite has no boolean: any non-zero integer is true.
    public var boolValue: Bool? { int64.map { $0 != 0 } }
    /// A timestamp stored as microseconds since the Unix epoch (this app's convention).
    public var dateFromMicros: Date? { int64.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) } }
    public var blobValue: [UInt8]? { if case .blob(let b) = self { return b }; return nil }

    public var displayString: String {
        switch self {
        case .null: return "NULL"
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .text(let s): return s
        case .blob(let b): return "\(b.count) bytes"
        }
    }
}

/// A value bound to a `?` placeholder.
public enum SQLBind: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case blob([UInt8])
    /// Stored as INTEGER microseconds since the Unix epoch.
    case timestamp(micros: Int64)

    public static func optional(_ s: String?) -> SQLBind { s.map { .string($0) } ?? .null }
    public static func optional(_ i: Int?) -> SQLBind { i.map { .int(Int64($0)) } ?? .null }
    public static func optional(_ i: Int64?) -> SQLBind { i.map { .int($0) } ?? .null }
    public static func optional(_ d: Double?) -> SQLBind { d.map { .double($0) } ?? .null }
    public static func optional(_ b: Bool?) -> SQLBind { b.map { .bool($0) } ?? .null }
}

/// A materialised result.
public struct SQLResult: Sendable, Equatable {
    public let columns: [String]
    public let rows: [[SQLValue]]

    public init(columns: [String], rows: [[SQLValue]]) {
        self.columns = columns
        self.rows = rows
    }

    public var rowCount: Int { rows.count }
    /// First cell of the first row as text — for `SELECT count(*)` probes.
    public var scalarString: String? { rows.first?.first?.displayString }
}

/// One SQLite connection. Opened with WAL journaling and a busy timeout; foreign keys on.
///
/// **Concurrency:** `@unchecked Sendable` under a strict contract — every method is called
/// serially from the one actor that owns the instance (`AppDatabase`). The connection is
/// opened full-mutex as belt and braces.
public final class SQLite: @unchecked Sendable {
    private var db: OpaquePointer?
    public let path: String

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Opens (creating if needed) the database at `path`; `":memory:"` for a private one.
    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let handle = db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            if db != nil { sqlite3_close_v2(db) }
            throw SQLiteError.open(path: path, message: message)
        }
        sqlite3_busy_timeout(handle, 5000)
        try execScript("PRAGMA foreign_keys = ON;")
        if path != ":memory:" {
            try execScript("PRAGMA journal_mode = WAL;")
        }
    }

    deinit {
        if db != nil { sqlite3_close_v2(db) }
    }

    private var errorMessage: String {
        db.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection"
    }

    /// Runs a script of one or more statements without parameters or results (DDL,
    /// migrations, PRAGMAs).
    public func execScript(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &message)
        if rc != SQLITE_OK {
            let text = message.map { String(cString: $0) } ?? errorMessage
            if let message { sqlite3_free(message) }
            throw SQLiteError.exec(message: text)
        }
    }

    /// Runs exactly one statement with `?` parameters and returns its rows.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLBind] = []) throws -> SQLResult {
        var statement: OpaquePointer?
        var trailing = ""
        let rc: Int32 = sql.withCString { cString in
            var tail: UnsafePointer<CChar>?
            let code = sqlite3_prepare_v2(db, cString, -1, &statement, &tail)
            if let tail { trailing = String(cString: tail) }
            return code
        }
        guard rc == SQLITE_OK, let statement else {
            throw SQLiteError.prepare(sql: sql, message: errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        if !trailing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SQLiteError.prepare(sql: sql, message: "run() takes one statement; use execScript() for several")
        }

        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard expected == params.count else {
            throw SQLiteError.parameterCount(sql: sql, expected: expected, got: params.count)
        }
        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            let bound: Int32
            switch value {
            case .null: bound = sqlite3_bind_null(statement, index)
            case .bool(let b): bound = sqlite3_bind_int64(statement, index, b ? 1 : 0)
            case .int(let i): bound = sqlite3_bind_int64(statement, index, i)
            case .double(let d): bound = sqlite3_bind_double(statement, index, d)
            case .string(let s): bound = sqlite3_bind_text(statement, index, s, -1, Self.transient)
            case .blob(let bytes):
                if bytes.isEmpty {
                    bound = sqlite3_bind_zeroblob(statement, index, 0)
                } else {
                    bound = bytes.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
                }
            case .timestamp(let micros): bound = sqlite3_bind_int64(statement, index, micros)
            }
            if bound != SQLITE_OK {
                throw SQLiteError.bind(sql: sql, index: Int(index), message: errorMessage)
            }
        }

        let columnCount = Int(sqlite3_column_count(statement))
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows = [[SQLValue]]()
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                rows.append((0..<columnCount).map { Self.read(statement, Int32($0)) })
            } else if step == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.step(sql: sql, message: errorMessage)
            }
        }
        return SQLResult(columns: columns, rows: rows)
    }

    private static func read(_ statement: OpaquePointer, _ column: Int32) -> SQLValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .int(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .double(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            guard let text = sqlite3_column_text(statement, column) else { return .text("") }
            return .text(String(cString: text))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, column))
            guard count > 0, let pointer = sqlite3_column_blob(statement, column) else { return .blob([]) }
            return .blob([UInt8](UnsafeRawBufferPointer(start: pointer, count: count)))
        default: return .null
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
    public var changes: Int { Int(sqlite3_changes(db)) }

    /// The linked library's version, e.g. `3.51.0`.
    public static var libraryVersion: String { String(cString: sqlite3_libversion()) }
}
