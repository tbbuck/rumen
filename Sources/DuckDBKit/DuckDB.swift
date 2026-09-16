import CDuckDB

/// An error surfaced by DuckDB. We never swallow these — the underlying engine
/// message is carried through verbatim (see the project's error-handling rule).
public enum DuckError: Error, CustomStringConvertible {
    case open(String)
    case connect(String)
    case query(sql: String, message: String)
    case appender(String)

    public var description: String {
        switch self {
        case .open(let m):    return "DuckDB open failed: \(m)"
        case .connect(let m): return "DuckDB connect failed: \(m)"
        case .appender(let m): return "DuckDB appender failed: \(m)"
        case .query(let sql, let m):
            return "DuckDB query failed: \(m)\n  SQL: \(sql)"
        }
    }
}

/// Startup configuration for the engine. The default (`.init()`) reproduces the historical
/// behaviour of opening with a nil `duckdb_config`, so headless tests and dev builds are
/// unaffected. A shipped, notarized bundle populates it so the app loads its *own* `libduckdb`
/// + extensions with no `~/.duckdb` lookup and no network:
///   - `extensionDirectory` → DuckDB's `extension_directory` (where autoloading resolves).
///   - `allowUnsignedExtensions` must be `true` once the extensions are re-signed with our
///     Developer ID for notarization: that invalidates DuckDB's own extension signature, and
///     this flag is *startup-only* (it cannot be changed by a later `SET`), which is why it
///     has to travel through `duckdb_open_ext` rather than a `SET` statement.
///   - `disableAutoinstall` turns off `autoinstall_known_extensions` so a missing extension
///     never reaches out to the network from the shipped app.
public struct DuckDBConfig: Sendable {
    public var extensionDirectory: String?
    public var allowUnsignedExtensions: Bool
    public var disableAutoinstall: Bool

    public init(extensionDirectory: String? = nil,
                allowUnsignedExtensions: Bool = false,
                disableAutoinstall: Bool = false) {
        self.extensionDirectory = extensionDirectory
        self.allowUnsignedExtensions = allowUnsignedExtensions
        self.disableAutoinstall = disableAutoinstall
    }

    /// The `(name, value)` engine settings this maps to; empty for the default config.
    var settings: [(name: String, value: String)] {
        var s = [(name: String, value: String)]()
        if let extensionDirectory { s.append(("extension_directory", extensionDirectory)) }
        if allowUnsignedExtensions { s.append(("allow_unsigned_extensions", "true")) }
        if disableAutoinstall { s.append(("autoinstall_known_extensions", "false")) }
        return s
    }

    var isEmpty: Bool { settings.isEmpty }
}

/// A thin, in-process wrapper over the locally-linked libduckdb.
///
/// **Concurrency:** `@unchecked Sendable` under a strict contract — `run(_:)` must be
/// called serially (one at a time); `LakeSession` guarantees this by owning the instance
/// behind an actor. `interrupt()` is the one method safe to call concurrently with a
/// running query (`duckdb_interrupt` is thread-safe), which is how cancellation works.
public final class DuckDB: @unchecked Sendable {
    private var db: duckdb_database?
    /// Module-internal so `Appender` can bind to this connection; never exposed publicly.
    var conn: duckdb_connection?

    /// Opens a database. `path` nil (the default) opens an in-memory database, which is what
    /// we use before `ATTACH`-ing a DuckLake catalog. `config` defaults to empty, which passes
    /// a nil `duckdb_config` to the engine (the historical open path); a populated config is
    /// applied at startup — see `DuckDBConfig`.
    public init(path: String? = nil, config: DuckDBConfig = .init()) throws {
        var err: UnsafeMutablePointer<CChar>?

        // Only allocate a duckdb_config when settings are actually requested, so the default
        // open path is exactly what it was before this parameter existed. The defer is armed
        // before any throwing set, so a rejected option can't leak the config.
        var cfg: duckdb_config?
        defer { if cfg != nil { duckdb_destroy_config(&cfg) } }
        if !config.isEmpty {
            guard duckdb_create_config(&cfg) == DuckDBSuccess else {
                throw DuckError.open("could not allocate a DuckDB configuration")
            }
            for setting in config.settings {
                let state = setting.name.withCString { name in
                    setting.value.withCString { value in duckdb_set_config(cfg, name, value) }
                }
                if state != DuckDBSuccess {
                    throw DuckError.open("rejected config option '\(setting.name)' = '\(setting.value)'")
                }
            }
        }

        let state: duckdb_state = {
            if let path {
                return path.withCString { duckdb_open_ext($0, &db, cfg, &err) }
            }
            return duckdb_open_ext(nil, &db, cfg, &err)
        }()
        if state != DuckDBSuccess {
            let message = err.map { String(cString: $0) } ?? "unknown error"
            if let err { duckdb_free(err) }
            throw DuckError.open(message)
        }
        if duckdb_connect(db, &conn) != DuckDBSuccess {
            duckdb_close(&db)
            throw DuckError.connect("could not open a connection")
        }
    }

    deinit {
        if conn != nil { duckdb_disconnect(&conn) }
        if db != nil { duckdb_close(&db) }
    }

    /// Runs one SQL statement and returns its result, decoded column-by-column from the
    /// engine's native data chunks. `maxRows`, if given, caps how many rows are collected
    /// (the query still runs; collection stops early).
    @discardableResult
    public func run(_ sql: String, maxRows: Int? = nil) throws -> QueryResult {
        var result = duckdb_result()
        let state = sql.withCString { duckdb_query(conn, $0, &result) }
        defer { duckdb_destroy_result(&result) }

        if state != DuckDBSuccess {
            let message = duckdb_result_error(&result).map { String(cString: $0) } ?? "unknown error"
            throw DuckError.query(sql: sql, message: message)
        }
        return Self.readResult(&result, maxRows: maxRows)
    }

    /// Requests cancellation of the query currently running on this connection.
    /// Thread-safe; may be called while `run(_:)` is in flight.
    public func interrupt() {
        if conn != nil { duckdb_interrupt(conn) }
    }

    // MARK: - Result decoding

    /// Per-column decoding plan, computed once from the result (stable across chunks).
    private struct ColumnPlan {
        let rawType: duckdb_type
        let decimalScale: UInt8
        let decimalInternal: duckdb_type
    }

    static func readResult(_ result: inout duckdb_result, maxRows: Int?) -> QueryResult {
        let columnCount = Int(duckdb_column_count(&result))
        var columns = [DuckColumn]()
        var plans = [ColumnPlan]()
        columns.reserveCapacity(columnCount)
        plans.reserveCapacity(columnCount)

        for c in 0..<columnCount {
            let name = String(cString: duckdb_column_name(&result, UInt64(c)))
            var logical = duckdb_column_logical_type(&result, UInt64(c))
            let raw = duckdb_get_type_id(logical)
            var scale: UInt8 = 0
            var internalType = raw
            if raw == DUCKDB_TYPE_DECIMAL {
                scale = duckdb_decimal_scale(logical)
                internalType = duckdb_decimal_internal_type(logical)
            }
            duckdb_destroy_logical_type(&logical)
            columns.append(DuckColumn(name: name, type: DuckTypeID(raw)))
            plans.append(ColumnPlan(rawType: raw, decimalScale: scale, decimalInternal: internalType))
        }

        var rows = [[DuckValue]]()
        fetch: while true {
            var chunk = duckdb_fetch_chunk(result)
            if chunk == nil { break }
            defer { duckdb_destroy_data_chunk(&chunk) }

            let size = Int(duckdb_data_chunk_get_size(chunk))
            var data = [UnsafeRawPointer?](repeating: nil, count: columnCount)
            var validity = [UnsafeMutablePointer<UInt64>?](repeating: nil, count: columnCount)
            for c in 0..<columnCount {
                let vector = duckdb_data_chunk_get_vector(chunk, UInt64(c))
                data[c] = duckdb_vector_get_data(vector).map(UnsafeRawPointer.init)
                validity[c] = duckdb_vector_get_validity(vector)
            }
            for r in 0..<size {
                var row = [DuckValue]()
                row.reserveCapacity(columnCount)
                for c in 0..<columnCount {
                    row.append(decode(data[c], validity[c], row: r, plan: plans[c]))
                }
                rows.append(row)
                if let maxRows, rows.count >= maxRows { break fetch }
            }
        }
        return QueryResult(columns: columns, rows: rows)
    }

    private static func decode(
        _ data: UnsafeRawPointer?, _ validity: UnsafeMutablePointer<UInt64>?,
        row: Int, plan: ColumnPlan
    ) -> DuckValue {
        guard let data else { return .null }
        if let validity, !duckdb_validity_row_is_valid(validity, UInt64(row)) { return .null }

        switch plan.rawType {
        case DUCKDB_TYPE_BOOLEAN:
            return .bool(data.loadUnaligned(fromByteOffset: row, as: UInt8.self) != 0)
        case DUCKDB_TYPE_TINYINT:
            return .int(Int64(data.loadUnaligned(fromByteOffset: row, as: Int8.self)))
        case DUCKDB_TYPE_SMALLINT:
            return .int(Int64(data.loadUnaligned(fromByteOffset: row * 2, as: Int16.self)))
        case DUCKDB_TYPE_INTEGER:
            return .int(Int64(data.loadUnaligned(fromByteOffset: row * 4, as: Int32.self)))
        case DUCKDB_TYPE_BIGINT:
            return .int(data.loadUnaligned(fromByteOffset: row * 8, as: Int64.self))
        case DUCKDB_TYPE_UTINYINT:
            return .uint(UInt64(data.loadUnaligned(fromByteOffset: row, as: UInt8.self)))
        case DUCKDB_TYPE_USMALLINT:
            return .uint(UInt64(data.loadUnaligned(fromByteOffset: row * 2, as: UInt16.self)))
        case DUCKDB_TYPE_UINTEGER:
            return .uint(UInt64(data.loadUnaligned(fromByteOffset: row * 4, as: UInt32.self)))
        case DUCKDB_TYPE_UBIGINT:
            return .uint(data.loadUnaligned(fromByteOffset: row * 8, as: UInt64.self))
        case DUCKDB_TYPE_FLOAT:
            return .double(Double(data.loadUnaligned(fromByteOffset: row * 4, as: Float.self)))
        case DUCKDB_TYPE_DOUBLE:
            return .double(data.loadUnaligned(fromByteOffset: row * 8, as: Double.self))
        case DUCKDB_TYPE_HUGEINT:
            return .string(String(int128(hugeint(data, row))))
        case DUCKDB_TYPE_UHUGEINT:
            let h = data.loadUnaligned(fromByteOffset: row * 16, as: duckdb_uhugeint.self)
            return .string(String((UInt128(h.upper) << 64) | UInt128(h.lower)))
        case DUCKDB_TYPE_DECIMAL:
            return .string(formatDecimal(decimalRaw(data, row, plan.decimalInternal), scale: plan.decimalScale))
        case DUCKDB_TYPE_VARCHAR:
            return .string(readString(data, row))
        case DUCKDB_TYPE_BLOB, DUCKDB_TYPE_BIT:
            return .blob(readBytes(data, row))
        case DUCKDB_TYPE_UUID:
            return .string(formatUUID(hugeint(data, row)))
        case DUCKDB_TYPE_DATE:
            let d = duckdb_date(days: data.loadUnaligned(fromByteOffset: row * 4, as: Int32.self))
            return .string(formatDate(duckdb_from_date(d)))
        case DUCKDB_TYPE_TIME:
            let t = duckdb_time(micros: data.loadUnaligned(fromByteOffset: row * 8, as: Int64.self))
            return .string(formatTime(duckdb_from_time(t)))
        case DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_TZ:
            let ts = duckdb_timestamp(micros: data.loadUnaligned(fromByteOffset: row * 8, as: Int64.self))
            let text = formatTimestamp(duckdb_from_timestamp(ts))
            return .string(plan.rawType == DUCKDB_TYPE_TIMESTAMP_TZ ? text + "+00" : text)
        case DUCKDB_TYPE_TIMESTAMP_S:
            return .string(timestampFromScaled(data, row, 1_000_000))
        case DUCKDB_TYPE_TIMESTAMP_MS:
            return .string(timestampFromScaled(data, row, 1_000))
        case DUCKDB_TYPE_TIMESTAMP_NS:
            let micros = data.loadUnaligned(fromByteOffset: row * 8, as: Int64.self) / 1_000
            return .string(formatTimestamp(duckdb_from_timestamp(duckdb_timestamp(micros: micros))))
        case DUCKDB_TYPE_INTERVAL:
            let iv = data.loadUnaligned(fromByteOffset: row * 16, as: duckdb_interval.self)
            return .string(formatInterval(iv))
        default:
            // Not-yet-decoded types (list/struct/map/array/enum/union/geometry/variant/…).
            // The app can `CAST(col AS VARCHAR)` for display; this marks the raw type.
            return .string("<\(DuckTypeID(plan.rawType).label)>")
        }
    }

    // MARK: - Physical readers

    private static func hugeint(_ data: UnsafeRawPointer, _ row: Int) -> duckdb_hugeint {
        data.loadUnaligned(fromByteOffset: row * 16, as: duckdb_hugeint.self)
    }

    private static func int128(_ h: duckdb_hugeint) -> Int128 {
        let bits = (UInt128(UInt64(bitPattern: h.upper)) << 64) | UInt128(h.lower)
        return Int128(bitPattern: bits)
    }

    private static func decimalRaw(_ data: UnsafeRawPointer, _ row: Int, _ internalType: duckdb_type) -> Int128 {
        switch internalType {
        case DUCKDB_TYPE_SMALLINT: return Int128(data.loadUnaligned(fromByteOffset: row * 2, as: Int16.self))
        case DUCKDB_TYPE_INTEGER:  return Int128(data.loadUnaligned(fromByteOffset: row * 4, as: Int32.self))
        case DUCKDB_TYPE_BIGINT:   return Int128(data.loadUnaligned(fromByteOffset: row * 8, as: Int64.self))
        default:                   return int128(hugeint(data, row))   // HUGEINT-backed
        }
    }

    /// Reads a `duckdb_string_t` (16 bytes: length, then inlined chars ≤12 or a pointer).
    private static func stringBuffer(_ data: UnsafeRawPointer, _ row: Int) -> UnsafeRawBufferPointer {
        let element = data.advanced(by: row * MemoryLayout<duckdb_string_t>.stride)
        let length = Int(element.loadUnaligned(as: UInt32.self))
        let start: UnsafeRawPointer
        if length <= 12 {
            start = element.advanced(by: 4)                       // inlined chars
        } else {
            let ptr = element.loadUnaligned(fromByteOffset: 8, as: UnsafeMutablePointer<CChar>.self)
            start = UnsafeRawPointer(ptr)
        }
        return UnsafeRawBufferPointer(start: start, count: length)
    }

    private static func readString(_ data: UnsafeRawPointer, _ row: Int) -> String {
        String(decoding: stringBuffer(data, row), as: UTF8.self)
    }

    private static func readBytes(_ data: UnsafeRawPointer, _ row: Int) -> [UInt8] {
        [UInt8](stringBuffer(data, row))
    }

    // MARK: - Formatters (Foundation-free)

    private static func pad(_ value: Int, _ width: Int) -> String {
        let s = String(value)
        return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
    }

    private static func formatDate(_ d: duckdb_date_struct) -> String {
        "\(pad(Int(d.year), 4))-\(pad(Int(d.month), 2))-\(pad(Int(d.day), 2))"
    }

    private static func formatTime(_ t: duckdb_time_struct) -> String {
        var out = "\(pad(Int(t.hour), 2)):\(pad(Int(t.min), 2)):\(pad(Int(t.sec), 2))"
        if t.micros != 0 { out += "." + pad(Int(t.micros), 6) }
        return out
    }

    private static func formatTimestamp(_ ts: duckdb_timestamp_struct) -> String {
        "\(formatDate(ts.date)) \(formatTime(ts.time))"
    }

    private static func timestampFromScaled(_ data: UnsafeRawPointer, _ row: Int, _ toMicros: Int64) -> String {
        let micros = data.loadUnaligned(fromByteOffset: row * 8, as: Int64.self) * toMicros
        return formatTimestamp(duckdb_from_timestamp(duckdb_timestamp(micros: micros)))
    }

    private static func formatDecimal(_ value: Int128, scale: UInt8) -> String {
        if scale == 0 { return String(value) }
        let negative = value < 0
        let digits = String(value.magnitude)
        let s = Int(scale)
        let intPart: String
        let fracPart: String
        if digits.count <= s {
            intPart = "0"
            fracPart = String(repeating: "0", count: s - digits.count) + digits
        } else {
            let cut = digits.index(digits.endIndex, offsetBy: -s)
            intPart = String(digits[..<cut])
            fracPart = String(digits[cut...])
        }
        return (negative ? "-" : "") + intPart + "." + fracPart
    }

    private static func formatInterval(_ iv: duckdb_interval) -> String {
        var parts = [String]()
        if iv.months != 0 { parts.append("\(iv.months) months") }
        if iv.days != 0 { parts.append("\(iv.days) days") }
        if iv.micros != 0 || parts.isEmpty {
            let totalSeconds = iv.micros / 1_000_000
            let h = totalSeconds / 3600, m = (totalSeconds % 3600) / 60, sec = totalSeconds % 60
            parts.append("\(pad(Int(h), 2)):\(pad(Int(m), 2)):\(pad(Int(sec), 2))")
        }
        return parts.joined(separator: " ")
    }

    private static func formatUUID(_ h: duckdb_hugeint) -> String {
        // DuckDB stores UUIDs as a hugeint with the sign bit flipped for ordering.
        let hi = UInt64(bitPattern: h.upper) ^ 0x8000_0000_0000_0000
        let lo = h.lower
        var bytes = [UInt8]()
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((hi >> UInt64(shift)) & 0xFF)) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((lo >> UInt64(shift)) & 0xFF)) }
        let hex = bytes.map { pad2Hex($0) }
        let g = hex.joined()
        let s = Array(g)
        func range(_ a: Int, _ b: Int) -> String { String(s[a..<b]) }
        return "\(range(0,8))-\(range(8,12))-\(range(12,16))-\(range(16,20))-\(range(20,32))"
    }

    private static func pad2Hex(_ b: UInt8) -> String {
        let h = String(b, radix: 16, uppercase: false)
        return h.count == 1 ? "0" + h : h
    }
}
