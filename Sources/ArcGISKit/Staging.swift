import Foundation
import DuckDBKit

/// The per-run staging database (SPEC §5.6): a DuckDB file holding one `features` table
/// with a column per field, the geometry as WKB in `geom_wkb`, and `_chunk` so a retried
/// chunk can replace its own rows. Never the app database.
public final class StagingDatabase: @unchecked Sendable {
    public let path: String
    let db: DuckDB
    public let fields: [FieldRecord]
    public let oidField: String?
    public let hasZ: Bool
    public let hasM: Bool
    /// Fields that get a column (raster fields are skipped; the geometry field is the WKB column).
    public let stagedFields: [FieldRecord]

    /// Running bounding box of every geometry appended, and the WKB types seen — for the
    /// GeoParquet metadata at export.
    private(set) var bbox: BoundingBox?
    private(set) var geometryTypes: Set<String> = []
    private(set) var invalidGeometries: Int64 = 0

    /// Opens (creating if needed) the staging file and its table.
    public init(path: String, fields: [FieldRecord], oidField: String?, hasZ: Bool, hasM: Bool) throws {
        self.path = path
        self.fields = fields
        self.oidField = oidField
        self.hasZ = hasZ
        self.hasM = hasM
        self.stagedFields = fields.filter { $0.esriType != .geometry && $0.esriType != .raster }
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        db = try DuckDB(path: path)
        try db.run("INSTALL spatial;")
        try db.run("LOAD spatial;")
        let columns = stagedFields.map { "\(Self.quote($0.name)) \(Self.stagingType($0.esriType))" }
            + ["geom_wkb BLOB", "_chunk INTEGER"]
        try db.run("CREATE TABLE IF NOT EXISTS features (\(columns.joined(separator: ", ")));")
        try db.run("CREATE TABLE IF NOT EXISTS staging_meta (key VARCHAR PRIMARY KEY, value VARCHAR);")
        try restoreMeta()
    }

    /// The DuckDB column type a field is staged as. Dates become TIMESTAMP; GUIDs, times, and
    /// offset timestamps stay VARCHAR until export (their text forms vary by server).
    static func stagingType(_ type: EsriFieldType) -> String {
        switch type {
        case .oid, .bigInteger: return "BIGINT"
        case .integer: return "INTEGER"
        case .smallInteger: return "SMALLINT"
        case .double: return "DOUBLE"
        case .single: return "FLOAT"
        case .date: return "TIMESTAMP"
        case .dateOnly: return "DATE"
        case .blob: return "BLOB"
        default: return "VARCHAR"
        }
    }

    static func quote(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }

    /// Removes any rows a previous attempt at this chunk left behind.
    public func clearChunk(_ seq: Int) throws {
        try db.run("DELETE FROM features WHERE _chunk = ?;", [.int(Int64(seq))])
    }

    /// Appends a page's features for chunk `seq`. Returns the number appended.
    @discardableResult
    public func append(_ page: FeaturePage, chunk seq: Int) throws -> Int {
        // Map the page's field order onto the staged columns by name.
        let pageIndex = Dictionary(page.fields.enumerated().map { ($1.name.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let columnSources: [Int?] = stagedFields.map { pageIndex[$0.name.lowercased()] }
        let appender = try db.appender(table: "features")
        var appended = 0
        for feature in page.features {
            for (field, source) in zip(stagedFields, columnSources) {
                let value = source.map { feature.attributes[$0] } ?? .null
                try Self.append(value, as: field.esriType, to: appender)
            }
            if let geometry = feature.geometry {
                let encoded = WKBWriter.encode(geometry, hasZ: hasZ, hasM: hasM)
                try appender.appendBlob(encoded.bytes)
                geometryTypes.insert(encoded.typeName)
                extend(bbox: geometry)
            } else {
                try appender.appendNull()
            }
            try appender.append(Int32(seq))
            try appender.endRow()
            appended += 1
        }
        try appender.close()
        try saveMeta()
        return appended
    }

    static func append(_ value: AttributeValue, as type: EsriFieldType, to appender: Appender) throws {
        if value.isNull { try appender.appendNull(); return }
        switch type {
        case .oid, .bigInteger:
            if let i = value.int64 { try appender.append(i) } else { try appender.appendString(value.stringValue ?? "") }
        case .integer:
            if let i = value.int64, let v = Int32(exactly: i) { try appender.append(v) } else { try appender.appendNull() }
        case .smallInteger:
            if let i = value.int64, let v = Int16(exactly: i) { try appender.append(v) } else { try appender.appendNull() }
        case .double:
            if let d = value.doubleValue { try appender.append(d) } else { try appender.appendNull() }
        case .single:
            if let d = value.doubleValue { try appender.append(Float(d)) } else { try appender.appendNull() }
        case .date:
            // Epoch milliseconds → TIMESTAMP micros. A string here is a server quirk; keep it as NULL.
            if let ms = value.int64 { try appender.appendTimestamp(micros: ms * 1000) } else { try appender.appendNull() }
        case .dateOnly:
            if let ms = value.int64 { try appender.appendDate(days: Int32(ms / 86_400_000)) }
            else if let s = value.stringValue, let date = Self.parseDate(s) { try appender.appendDate(days: Int32(date.timeIntervalSince1970 / 86_400)) }
            else { try appender.appendNull() }
        case .blob:
            if let s = value.stringValue, let data = Data(base64Encoded: s) { try appender.appendBlob([UInt8](data)) } else { try appender.appendNull() }
        default:
            try appender.appendString(value.stringValue ?? "")
        }
    }

    private static func parseDate(_ s: String) -> Date? {
        try? Date(s, strategy: .iso8601.year().month().day())
    }

    private func extend(bbox geometry: EsriGeometry) {
        func visit(_ c: [Double]) {
            guard c.count >= 2, c[0].isFinite, c[1].isFinite else { return }
            let box = BoundingBox(minX: c[0], minY: c[1], maxX: c[0], maxY: c[1])
            bbox = bbox.map { $0.union(box) } ?? box
        }
        switch geometry {
        case .point(let c): visit(c)
        case .multipoint(let p): p.forEach(visit)
        case .polyline(let paths): paths.forEach { $0.forEach(visit) }
        case .polygon(let rings): rings.forEach { $0.forEach(visit) }
        case .envelope(let xmin, let ymin, let xmax, let ymax): visit([xmin, ymin]); visit([xmax, ymax])
        }
    }

    // MARK: - Metadata (survives a crash: bbox and types are re-read on reopen)

    private func saveMeta() throws {
        let entries: [(String, String)] = [
            ("bbox", bbox?.json ?? ""),
            ("types", geometryTypes.sorted().joined(separator: ",")),
        ]
        for (key, value) in entries {
            try db.run("INSERT OR REPLACE INTO staging_meta VALUES (?, ?);", [.string(key), .string(value)])
        }
    }

    private func restoreMeta() throws {
        for row in try db.run("SELECT key, value FROM staging_meta;").rows {
            switch row[0].stringValue {
            case "bbox": bbox = BoundingBox(json: row[1].stringValue)
            case "types": geometryTypes = Set((row[1].stringValue ?? "").split(separator: ",").map(String.init)).filter { !$0.isEmpty }
            default: break
            }
        }
    }

    public func rowCount() throws -> Int64 {
        Int64(try db.run("SELECT count(*) FROM features;").scalarString ?? "0") ?? 0
    }

    /// Counts geometries the spatial extension considers invalid (reported, never repaired).
    public func countInvalidGeometries() throws -> Int64 {
        let n = try db.run("SELECT count(*) FROM features WHERE geom_wkb IS NOT NULL AND NOT ST_IsValid(ST_GeomFromWKB(geom_wkb));").scalarString
        invalidGeometries = Int64(n ?? "0") ?? 0
        return invalidGeometries
    }

    /// Runs a statement on the staging connection (export uses this).
    @discardableResult
    func run(_ sql: String, _ params: [BindValue] = []) throws -> QueryResult {
        params.isEmpty ? try db.run(sql) : try db.run(sql, params)
    }
}
