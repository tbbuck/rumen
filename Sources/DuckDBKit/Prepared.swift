import CDuckDB

/// A value bound to a `?` placeholder in a prepared statement. Distinct from `DuckValue`
/// (the decoded read side) because binding needs native temporal types.
public enum BindValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case blob([UInt8])
    /// TIMESTAMP as microseconds since the Unix epoch (UTC).
    case timestamp(micros: Int64)
    /// DATE as days since the Unix epoch.
    case date(days: Int32)

    /// Convenience: nil → `.null`, else the wrapped value.
    public static func optional(_ s: String?) -> BindValue { s.map { .string($0) } ?? .null }
    public static func optional(_ i: Int?) -> BindValue { i.map { .int(Int64($0)) } ?? .null }
    public static func optional(_ i: Int64?) -> BindValue { i.map { .int($0) } ?? .null }
    public static func optional(_ d: Double?) -> BindValue { d.map { .double($0) } ?? .null }
    public static func optional(_ b: Bool?) -> BindValue { b.map { .bool($0) } ?? .null }
}

extension DuckDB {
    /// Runs one parameterised statement. Placeholders are `?`, bound in order. The parameter
    /// count must match the statement's, and any bind or execution failure carries the
    /// engine's own message.
    @discardableResult
    public func run(_ sql: String, _ params: [BindValue], maxRows: Int? = nil) throws -> QueryResult {
        var statement: duckdb_prepared_statement?
        defer { if statement != nil { duckdb_destroy_prepare(&statement) } }

        let prepared = sql.withCString { duckdb_prepare(conn, $0, &statement) }
        if prepared != DuckDBSuccess {
            let message = duckdb_prepare_error(statement).map { String(cString: $0) } ?? "prepare failed"
            throw DuckError.query(sql: sql, message: message)
        }
        let expected = Int(duckdb_nparams(statement))
        guard expected == params.count else {
            throw DuckError.query(sql: sql, message: "statement has \(expected) parameters but \(params.count) were bound")
        }
        for (offset, value) in params.enumerated() {
            let index = idx_t(offset + 1)
            let state: duckdb_state
            switch value {
            case .null: state = duckdb_bind_null(statement, index)
            case .bool(let b): state = duckdb_bind_boolean(statement, index, b)
            case .int(let i): state = duckdb_bind_int64(statement, index, i)
            case .double(let d): state = duckdb_bind_double(statement, index, d)
            case .string(let s):
                var copy = s
                state = copy.withUTF8 { duckdb_bind_varchar_length(statement, index, $0.baseAddress, idx_t($0.count)) }
            case .blob(let bytes):
                state = bytes.withUnsafeBytes { duckdb_bind_blob(statement, index, $0.baseAddress, idx_t($0.count)) }
            case .timestamp(let micros): state = duckdb_bind_timestamp(statement, index, duckdb_timestamp(micros: micros))
            case .date(let days): state = duckdb_bind_date(statement, index, duckdb_date(days: days))
            }
            if state != DuckDBSuccess {
                throw DuckError.query(sql: sql, message: "could not bind parameter \(index)")
            }
        }

        var result = duckdb_result()
        let executed = duckdb_execute_prepared(statement, &result)
        defer { duckdb_destroy_result(&result) }
        if executed != DuckDBSuccess {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown error"
            throw DuckError.query(sql: sql, message: message)
        }
        return Self.readResult(&result, maxRows: maxRows)
    }
}
