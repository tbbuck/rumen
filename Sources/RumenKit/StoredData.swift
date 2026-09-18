import Foundation
import DuckDBKit

/// Geometry read back from a downloaded GeoParquet, simplified for display.
public struct StoredSample: Sendable, Equatable {
    public let geoJSON: String
    public let shown: Int
    public let total: Int
    public let simplified: Bool
}

extension AppDatabase {
    /// Rows of a stored GeoParquet as a GeoJSON FeatureCollection, through the spatial engine.
    /// `whereClause` is DuckDB SQL over the file's columns. Large sets are simplified for the
    /// screen and capped at `limit` features; the total is reported alongside.
    public func storedSample(path: String, whereClause: String = "", limit: Int = 5000) throws -> StoredSample {
        guard let spatial else { throw SpatialError.notLoaded }
        let filter = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
        let whereSQL = filter.isEmpty ? "" : " WHERE \(filter)"
        let file = path.replacingOccurrences(of: "'", with: "''")
        let total = Int(try spatial.run("SELECT count(*) FROM read_parquet('\(file)')\(whereSQL);").scalarString ?? "0") ?? 0
        let simplify = total > 2000
        let geometry = simplify ? "ST_Simplify(geometry, 0.0005)" : "geometry"
        let rows = try spatial.run("""
            SELECT ST_AsGeoJSON(\(geometry)), to_json(struct_pack(*COLUMNS(* EXCLUDE (geometry))))
            FROM read_parquet('\(file)')\(whereSQL) LIMIT \(max(1, limit));
            """).rows
        let features = rows.compactMap { row -> String? in
            guard let geometry = row[0].stringValue, !geometry.isEmpty else { return nil }
            let properties = Self.orderedProperties(row.count > 1 ? row[1].stringValue : nil)
            return #"{"type":"Feature","properties":\#(properties),"geometry":\#(geometry)}"#
        }
        return StoredSample(geoJSON: GeoJSON.featureCollection(features), shown: features.count, total: total, simplified: simplify)
    }

    /// Reprojects lon/lat pairs to an EPSG code, or back, in one query. Non-finite results
    /// come back as NaN. Throws if the spatial engine is not loaded.
    /// A GeoJSON or GML body rewritten as RFC 7946 GeoJSON in WGS 84 by the spatial engine
    /// (M10): what the map draws when a WFS answers in GML or in a projected reference it
    /// would not translate. `sourceWkid` is the coordinates' reference; nil means WGS 84.
    public func geoJSONInWGS84(data: Data, fileExtension: String, sourceWkid: Int?) throws -> String {
        guard let spatial else { throw SpatialError.notLoaded }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rumen-map-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("sample.\(fileExtension)")
        let output = directory.appendingPathComponent("sample-wgs84.geojson")
        try data.write(to: input)
        let source = "ST_Read('\(input.path.replacingOccurrences(of: "'", with: "''"))')"
        var geometry: String?
        var attributes = [String]()
        for row in try spatial.run("DESCRIBE SELECT * FROM \(source);").rows {
            guard let name = row[0].stringValue, let type = row[1].stringValue else { continue }
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            if type.uppercased().hasPrefix("GEOMETRY"), geometry == nil { geometry = quoted }
            else if name != "OGC_FID", name != "lowerCorner", name != "upperCorner" { attributes.append(quoted) }
        }
        guard let geometry else { throw SpatialError.notLoaded }
        let wkid = sourceWkid ?? 4326
        let projected = wkid == 4326 ? geometry : "ST_Transform(\(geometry), 'EPSG:\(wkid)', 'EPSG:4326', always_xy := true)"
        let select = (attributes + ["\(projected) AS geometry"]).joined(separator: ", ")
        try spatial.run("SET geometry_always_xy = true;")
        try spatial.run("COPY (SELECT \(select) FROM \(source)) TO '\(output.path.replacingOccurrences(of: "'", with: "''"))' WITH (FORMAT gdal, DRIVER 'GeoJSON', LAYER_CREATION_OPTIONS 'RFC7946=YES', SRS 'EPSG:4326');")
        return try String(contentsOf: output, encoding: .utf8)
    }

    public func transform(_ points: [(Double, Double)], from source: Int, to target: Int) throws -> [(Double, Double)] {
        guard let spatial else { throw SpatialError.notLoaded }
        guard !points.isEmpty else { return [] }
        if source == target { return points }
        let values = points.enumerated().map { i, p in "(\(i), \(p.0), \(p.1))" }.joined(separator: ",")
        let rows = try spatial.run("""
            WITH pts(i, x, y) AS (VALUES \(values)),
                 t AS (SELECT i, ST_Transform(ST_Point(x, y), 'EPSG:\(source)', 'EPSG:\(target)', always_xy := true) AS g FROM pts)
            SELECT ST_X(g), ST_Y(g) FROM t ORDER BY i;
            """).rows
        return rows.map { ($0[0].doubleValue ?? .nan, $0[1].doubleValue ?? .nan) }
    }
}

extension AppDatabase {
    /// Re-keys a row's JSON object with its position so the info panel keeps column order
    /// (`"003|POP2000"`), values rendered as text.
    static func orderedProperties(_ json: String?) -> String {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any],
              let ordered = try? JSONDecoder().decode(OrderedKeys.self, from: data) else { return "{}" }
        var out = [String: String]()
        for (index, key) in ordered.keys.enumerated() {
            let value = object[key]
            out[String(format: "%03d|%@", index, key)] = value == nil || value is NSNull ? "NULL" : "\(value!)"
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: encoded, as: UTF8.self)
    }

    /// Captures object key order, which `JSONSerialization` discards.
    private struct OrderedKeys: Decodable {
        let keys: [String]
        struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }
        init(from decoder: Decoder) throws {
            keys = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue)
        }
    }
}

// MARK: - Stored files (M7)

/// A downloaded GeoParquet opened through its own spatial engine for the Stored tab: the rows
/// as a grid, a SQL scratch box over a `data` view, counts, and file facts. One connection per
/// open file, owned by this actor, so the app database never waits behind a long query.
public actor StoredFile {
    public let path: String
    private let db: DuckDB

    /// The view the scratch box's SQL sees the file as.
    public static let viewName = "data"
    public static let defaultSQL = "SELECT * FROM data"

    public struct Column: Sendable, Equatable {
        public let name: String
        public let type: String
    }

    public struct Summary: Sendable, Equatable {
        public let rows: Int64
        public let bytes: Int64
        public let columns: [Column]
    }

    /// The rows of one query, rendered for the grid; `total` is the whole result's size when
    /// the grid stopped short of it.
    public struct Page: Sendable, Equatable {
        public let grid: QueryGrid
        public let total: Int64
        public let truncated: Bool
    }

    public init(path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { throw ExportError.missingSource(path) }
        self.path = path
        db = try DuckDB()
        try db.run("INSTALL spatial;")
        try db.run("LOAD spatial;")
        try db.run("CREATE VIEW \(Self.viewName) AS SELECT * FROM read_parquet('\(Exporter.escape(path))');")
    }

    public func summary() throws -> Summary {
        let rows = Int64(try db.run("SELECT count(*) FROM \(Self.viewName);").scalarString ?? "0") ?? 0
        let columns = try db.run("DESCRIBE \(Self.viewName);").rows.compactMap { row -> Column? in
            guard let name = row[0].stringValue, let type = row[1].stringValue else { return nil }
            return Column(name: name, type: type)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        return Summary(rows: rows, bytes: bytes, columns: columns)
    }

    /// Runs SQL over the file. The statement becomes a view so its columns are known before any
    /// row is read: geometry is rendered as a WKT point or a shape summary, nested types as
    /// text, and the grid stops at `limit` rows. DuckDB's own message is thrown verbatim.
    public func query(_ sql: String, limit: Int = 1000) throws -> Page {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") { text = String(text.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        try db.run("CREATE OR REPLACE TEMP VIEW scratch AS \(text);")
        let described = try db.run("DESCRIBE scratch;").rows.compactMap { row -> Column? in
            guard let name = row[0].stringValue, let type = row[1].stringValue else { return nil }
            return Column(name: name, type: type)
        }
        let select = described.map { column -> String in
            let q = StagingDatabase.quote(column.name)
            if column.type.hasPrefix("GEOMETRY") { return "\(Self.geometrySummary(q)) AS \(q)" }
            return Self.isScalar(column.type) ? q : "\(q)::VARCHAR AS \(q)"
        }.joined(separator: ", ")
        let result = try db.run("SELECT \(select) FROM scratch LIMIT \(max(1, limit) + 1);")
        let truncated = result.rows.count > limit
        let shown = Array(result.rows.prefix(limit))
        let total = truncated ? (Int64(try db.run("SELECT count(*) FROM scratch;").scalarString ?? "0") ?? Int64(shown.count))
                              : Int64(shown.count)
        let columns = zip(described, result.columns).map { column, decoded in
            GridColumn(name: column.name, typeLabel: column.type, isNumeric: decoded.type.isNumeric)
        }
        let grid = QueryGrid(columns: columns, rows: shown.map { $0.map(\.displayString) })
        return Page(grid: grid, total: total, truncated: truncated)
    }

    /// WKT for a point, else the shape and its vertex count: what fits in a cell.
    static func geometrySummary(_ q: String) -> String {
        "CASE WHEN \(q) IS NULL THEN NULL WHEN ST_GeometryType(\(q)) = 'POINT' THEN ST_AsText(\(q)) " +
        "ELSE ST_GeometryType(\(q))::VARCHAR || ', ' || ST_NPoints(\(q))::VARCHAR || ' vertices' END"
    }

    /// Types the engine decodes natively; anything else (lists, structs, maps, enums, unions)
    /// is cast to text for display.
    static func isScalar(_ type: String) -> Bool {
        let scalars = ["BOOLEAN", "TINYINT", "SMALLINT", "INTEGER", "BIGINT", "HUGEINT", "UTINYINT", "USMALLINT",
                       "UINTEGER", "UBIGINT", "UHUGEINT", "FLOAT", "DOUBLE", "DECIMAL", "VARCHAR", "BLOB", "UUID",
                       "BIT", "DATE", "TIME", "TIMESTAMP", "INTERVAL"]
        return scalars.contains { type.hasPrefix($0) } && !type.hasSuffix("[]")
    }
}
