import CDuckDB

/// A DuckDB column's logical type, mapped from the C `duckdb_type` enum. Carries just
/// enough to drive rendering (e.g. numeric right-alignment) and decoding decisions.
public enum DuckTypeID: Sendable, Equatable {
    case boolean
    case tinyint, smallint, integer, bigint, hugeint
    case utinyint, usmallint, uinteger, ubigint, uhugeint
    case float, double, decimal
    case varchar, blob, uuid, bit
    case date, time, timestamp, timestampTZ, interval
    case list, structType, map, array, enumType, union, geometry, variant
    case other(UInt32)

    init(_ raw: duckdb_type) {
        switch raw {
        case DUCKDB_TYPE_BOOLEAN: self = .boolean
        case DUCKDB_TYPE_TINYINT: self = .tinyint
        case DUCKDB_TYPE_SMALLINT: self = .smallint
        case DUCKDB_TYPE_INTEGER: self = .integer
        case DUCKDB_TYPE_BIGINT: self = .bigint
        case DUCKDB_TYPE_HUGEINT: self = .hugeint
        case DUCKDB_TYPE_UTINYINT: self = .utinyint
        case DUCKDB_TYPE_USMALLINT: self = .usmallint
        case DUCKDB_TYPE_UINTEGER: self = .uinteger
        case DUCKDB_TYPE_UBIGINT: self = .ubigint
        case DUCKDB_TYPE_UHUGEINT: self = .uhugeint
        case DUCKDB_TYPE_FLOAT: self = .float
        case DUCKDB_TYPE_DOUBLE: self = .double
        case DUCKDB_TYPE_DECIMAL: self = .decimal
        case DUCKDB_TYPE_VARCHAR: self = .varchar
        case DUCKDB_TYPE_BLOB: self = .blob
        case DUCKDB_TYPE_UUID: self = .uuid
        case DUCKDB_TYPE_BIT: self = .bit
        case DUCKDB_TYPE_DATE: self = .date
        case DUCKDB_TYPE_TIME: self = .time
        case DUCKDB_TYPE_TIMESTAMP, DUCKDB_TYPE_TIMESTAMP_S,
             DUCKDB_TYPE_TIMESTAMP_MS, DUCKDB_TYPE_TIMESTAMP_NS:
            self = .timestamp
        case DUCKDB_TYPE_TIMESTAMP_TZ: self = .timestampTZ
        case DUCKDB_TYPE_INTERVAL: self = .interval
        case DUCKDB_TYPE_LIST: self = .list
        case DUCKDB_TYPE_STRUCT: self = .structType
        case DUCKDB_TYPE_MAP: self = .map
        case DUCKDB_TYPE_ARRAY: self = .array
        case DUCKDB_TYPE_ENUM: self = .enumType
        case DUCKDB_TYPE_UNION: self = .union
        case DUCKDB_TYPE_GEOMETRY: self = .geometry
        case DUCKDB_TYPE_VARIANT: self = .variant
        default: self = .other(raw.rawValue)
        }
    }

    /// True for types that should render right-aligned in a grid.
    public var isNumeric: Bool {
        switch self {
        case .tinyint, .smallint, .integer, .bigint, .hugeint,
             .utinyint, .usmallint, .uinteger, .ubigint, .uhugeint,
             .float, .double, .decimal:
            return true
        default:
            return false
        }
    }

    /// A short label for headers / unsupported-type placeholders.
    public var label: String {
        switch self {
        case .boolean: return "BOOLEAN"
        case .tinyint: return "TINYINT"
        case .smallint: return "SMALLINT"
        case .integer: return "INTEGER"
        case .bigint: return "BIGINT"
        case .hugeint: return "HUGEINT"
        case .utinyint: return "UTINYINT"
        case .usmallint: return "USMALLINT"
        case .uinteger: return "UINTEGER"
        case .ubigint: return "UBIGINT"
        case .uhugeint: return "UHUGEINT"
        case .float: return "FLOAT"
        case .double: return "DOUBLE"
        case .decimal: return "DECIMAL"
        case .varchar: return "VARCHAR"
        case .blob: return "BLOB"
        case .uuid: return "UUID"
        case .bit: return "BIT"
        case .date: return "DATE"
        case .time: return "TIME"
        case .timestamp: return "TIMESTAMP"
        case .timestampTZ: return "TIMESTAMPTZ"
        case .interval: return "INTERVAL"
        case .list: return "LIST"
        case .structType: return "STRUCT"
        case .map: return "MAP"
        case .array: return "ARRAY"
        case .enumType: return "ENUM"
        case .union: return "UNION"
        case .geometry: return "GEOMETRY"
        case .variant: return "VARIANT"
        case .other(let raw): return "TYPE(\(raw))"
        }
    }
}

/// A decoded cell value. Common scalar types are modelled natively; temporal, decimal,
/// hugeint, uuid, and not-yet-supported nested types are decoded to a faithful text form
/// (see `DuckDB.readResult`).
public enum DuckValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case blob([UInt8])

    public var isNull: Bool { self == .null }

    /// The signed-integer payload, if this is an integer value (unsigned promoted when it fits).
    public var int64: Int64? {
        switch self {
        case .int(let v): return v
        case .uint(let v): return Int64(exactly: v)
        default: return nil
        }
    }

    /// The string payload, if this is a `.string` value (not a rendered form of another type).
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// A human-readable rendering for grids and probes.
    public var displayString: String {
        switch self {
        case .null: return "NULL"
        case .bool(let b): return b ? "true" : "false"
        case .int(let v): return String(v)
        case .uint(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let s): return s
        case .blob(let bytes):
            let hex = bytes.prefix(24).map { String($0, radix: 16, uppercase: false) }
                .map { $0.count == 1 ? "0" + $0 : $0 }.joined()
            return bytes.count > 24 ? "\\x\(hex)… (\(bytes.count) bytes)" : "\\x\(hex)"
        }
    }
}

/// A result column: its name and logical type.
public struct DuckColumn: Sendable, Equatable {
    public let name: String
    public let type: DuckTypeID

    public init(name: String, type: DuckTypeID) {
        self.name = name
        self.type = type
    }
}

/// A materialised, typed query result.
public struct QueryResult: Sendable {
    public let columns: [DuckColumn]
    public let rows: [[DuckValue]]

    public init(columns: [DuckColumn], rows: [[DuckValue]]) {
        self.columns = columns
        self.rows = rows
    }

    public var columnNames: [String] { columns.map(\.name) }
    public var rowCount: Int { rows.count }

    /// First cell of the first row rendered as text — handy for `SELECT count(*)` probes.
    public var scalarString: String? { rows.first?.first?.displayString }
}
