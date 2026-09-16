import CDuckDB

/// A row-at-a-time writer over DuckDB's C Appender API — the fast path for streaming
/// downloaded features into a staging table (SPEC §5.6).
///
/// Usage: append one value per column in table order, then `endRow()`; `flush()` pushes
/// buffered rows to the table; `close()` flushes and finalises. Any failure invalidates the
/// appender: the engine's own message is thrown and the appender must be discarded.
///
/// **Concurrency:** not `Sendable` by design. Create it from, and use it on, the same actor
/// that owns the `DuckDB` connection it was created on.
public final class Appender {
    private var appender: duckdb_appender?

    /// Binds to `table` (optionally schema-qualified) on `db`'s connection.
    init(db: DuckDB, schema: String?, table: String) throws {
        let state: duckdb_state = table.withCString { tablePtr in
            if let schema {
                return schema.withCString { schemaPtr in
                    duckdb_appender_create(db.conn, schemaPtr, tablePtr, &appender)
                }
            }
            return duckdb_appender_create(db.conn, nil, tablePtr, &appender)
        }
        if state != DuckDBSuccess {
            let message = errorMessage()
            if appender != nil { duckdb_appender_destroy(&appender) }
            throw DuckError.appender(message)
        }
    }

    deinit {
        // Destroy also flushes; a failure here has nowhere to go, but `close()` is the
        // supported path and reports it, so callers should always close explicitly.
        if appender != nil { duckdb_appender_destroy(&appender) }
    }

    /// Number of columns each row must supply.
    public var columnCount: Int {
        Int(duckdb_appender_column_count(appender))
    }

    // MARK: - Typed appends

    public func append(_ value: DuckValue) throws {
        switch value {
        case .null:            try check(duckdb_append_null(appender))
        case .bool(let b):     try check(duckdb_append_bool(appender, b))
        case .int(let i):      try check(duckdb_append_int64(appender, i))
        case .uint(let u):     try check(duckdb_append_uint64(appender, u))
        case .double(let d):   try check(duckdb_append_double(appender, d))
        case .string(let s):   try appendString(s)
        case .blob(let bytes): try appendBlob(bytes)
        }
    }

    public func appendNull() throws { try check(duckdb_append_null(appender)) }
    public func append(_ value: Bool) throws { try check(duckdb_append_bool(appender, value)) }
    public func append(_ value: Int32) throws { try check(duckdb_append_int32(appender, value)) }
    public func append(_ value: Int64) throws { try check(duckdb_append_int64(appender, value)) }
    public func append(_ value: Double) throws { try check(duckdb_append_double(appender, value)) }

    public func appendString(_ value: String) throws {
        var copy = value
        try copy.withUTF8 { buffer in
            try check(duckdb_append_varchar_length(appender, buffer.baseAddress, idx_t(buffer.count)))
        }
    }

    public func appendBlob(_ bytes: [UInt8]) throws {
        try bytes.withUnsafeBytes { buffer in
            try check(duckdb_append_blob(appender, buffer.baseAddress, idx_t(buffer.count)))
        }
    }

    /// Appends a TIMESTAMP from microseconds since the Unix epoch (UTC).
    public func appendTimestamp(micros: Int64) throws {
        try check(duckdb_append_timestamp(appender, duckdb_timestamp(micros: micros)))
    }

    /// Appends a DATE from days since the Unix epoch.
    public func appendDate(days: Int32) throws {
        try check(duckdb_append_date(appender, duckdb_date(days: days)))
    }

    /// Appends a TIME from microseconds since midnight.
    public func appendTime(micros: Int64) throws {
        try check(duckdb_append_time(appender, duckdb_time(micros: micros)))
    }

    // MARK: - Row / lifecycle

    public func endRow() throws { try check(duckdb_appender_end_row(appender)) }

    /// Pushes buffered rows to the table. Rows become visible to queries on the same
    /// connection after this (and after `close()`).
    public func flush() throws { try check(duckdb_appender_flush(appender)) }

    /// Flushes and finalises. The appender cannot be used afterwards.
    public func close() throws {
        guard appender != nil else { return }
        let state = duckdb_appender_close(appender)
        let message = state == DuckDBSuccess ? "" : errorMessage()
        duckdb_appender_destroy(&appender)
        if state != DuckDBSuccess { throw DuckError.appender(message) }
    }

    // MARK: - Errors

    private func check(_ state: duckdb_state) throws {
        if state != DuckDBSuccess { throw DuckError.appender(errorMessage()) }
    }

    /// The engine's message for the last failure. The C string is owned by the appender and
    /// freed on destroy, so it is copied out immediately.
    private func errorMessage() -> String {
        guard appender != nil, let cString = duckdb_appender_error(appender) else {
            return "unknown appender error"
        }
        return String(cString: cString)
    }
}

extension DuckDB {
    /// Creates an appender bound to `table` on this connection. Must be used on the same
    /// actor as this `DuckDB` (see `Appender`).
    public func appender(table: String, schema: String? = nil) throws -> Appender {
        try Appender(db: self, schema: schema, table: table)
    }

    /// The linked engine's version string, e.g. `v1.5.5`.
    public static var libraryVersion: String {
        String(cString: duckdb_library_version())
    }
}
