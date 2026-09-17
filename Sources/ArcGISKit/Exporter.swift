import Foundation
import CryptoKit
import DuckDBKit

public enum ExportError: Error, CustomStringConvertible, Equatable {
    case outputExists(String)
    case unsupportedFormat(ExportFormat)
    case missingSource(String)

    public var description: String {
        switch self {
        case .outputExists(let p): return "output file already exists: \(p)"
        case .unsupportedFormat(let f): return "re-export as \(f.label) is not offered; download the layer again in that format instead"
        case .missingSource(let p): return "the stored file is missing: \(p)"
        }
    }
}

public struct ExportResult: Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let bytes: Int64
    public let featureCount: Int64
    public let invalidGeometries: Int64

    public init(path: String, sha256: String, bytes: Int64, featureCount: Int64, invalidGeometries: Int64) {
        self.path = path
        self.sha256 = sha256
        self.bytes = bytes
        self.featureCount = featureCount
        self.invalidGeometries = invalidGeometries
    }
}

/// Writes features to the chosen format (SPEC §5.7), either from a download's staging table or
/// from a stored GeoParquet (a re-export, which never touches the server).
///
/// - GeoParquet: the WKB column as `geometry` with our own `geo` metadata (geometry types,
///   bbox, and the CRS as PROJJSON from DuckDB's registry), because DuckDB's writer omits the CRS.
/// - GeoJSON: the spatial extension's GDAL writer, RFC 7946, so the geometry is reprojected to
///   WGS 84 first when the data is in anything else.
/// - CSV: DuckDB's CSV writer with the geometry as WKT in a `geometry` column.
public enum Exporter {
    /// Sanitised `<dir>/<server>/<service>/<layer>.<ext>`.
    public static func outputPath(directory: URL, server: ServerRecord, service: ServiceRecord, layer: LayerRecord,
                                  format: ExportFormat) -> URL {
        directory.appendingPathComponent(component(server.friendlyName))
            .appendingPathComponent(component(service.name))
            .appendingPathComponent(component(layer.name))
            .appendingPathExtension(format.fileExtension)
    }

    /// Where a re-export of a stored file lands: beside it, with the format's extension.
    public static func siblingPath(of stored: URL, format: ExportFormat) -> URL {
        stored.deletingPathExtension().appendingPathExtension(format.fileExtension)
    }

    static func component(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty || out == "." || out == ".." { out = "_" }
        return out
    }

    // MARK: - From a download's staging table

    public static func export(_ staging: StagingDatabase, to url: URL, format: ExportFormat, outWkid: Int,
                              domainLabels: Bool, overwrite: Bool) throws -> ExportResult {
        guard !format.isRaster else { throw ExportError.unsupportedFormat(format) }
        try prepare(url, overwrite: overwrite)
        let selectList = try columns(staging, format: format, domainLabels: domainLabels)
        let orderBy = staging.oidField.map { " ORDER BY \(StagingDatabase.quote($0))" } ?? ""
        let invalid = try staging.countInvalidGeometries()
        switch format {
        case .geoParquet:
            let metadata = try geoMetadata(staging, outWkid: outWkid)
            try staging.run("""
                COPY (SELECT \(selectList), geom_wkb AS geometry FROM features\(orderBy))
                TO '\(escape(url.path))' (FORMAT PARQUET, KV_METADATA {geo: '\(escape(metadata))'});
                """)
        case .geoJSON:
            try staging.run("SET geometry_always_xy = true;")
            try staging.run(geoJSONCopy(
                select: "\(selectList), \(wgs84("ST_GeomFromWKB(geom_wkb)", from: outWkid)) AS geometry FROM features\(orderBy)",
                to: url))
        case .csv:
            try staging.run(csvCopy(select: "\(selectList), ST_AsText(ST_GeomFromWKB(geom_wkb)) AS geometry FROM features\(orderBy)", to: url))
        case .png, .geoTIFF:
            throw ExportError.unsupportedFormat(format)
        }
        let count = try staging.rowCount()
        let (hash, bytes) = try hashFile(at: url)
        return ExportResult(path: url.path, sha256: hash, bytes: bytes, featureCount: count, invalidGeometries: invalid)
    }

    /// The exported columns: staged types with GUIDs cast to UUID (GeoParquet) or trimmed to
    /// plain text (the other writers), time-ish strings cast to their types, and optional
    /// `<field>_label` columns decoded from coded-value domains.
    static func columns(_ staging: StagingDatabase, format: ExportFormat, domainLabels: Bool) throws -> String {
        var parts = [String]()
        for field in staging.stagedFields {
            let q = StagingDatabase.quote(field.name)
            switch field.esriType {
            case .guid, .globalID:
                parts.append(format == .geoParquet ? "TRY_CAST(trim(\(q), '{}') AS UUID) AS \(q)" : "trim(\(q), '{}') AS \(q)")
            case .timeOnly:
                parts.append("TRY_CAST(\(q) AS TIME) AS \(q)")
            case .timestampOffset:
                parts.append("TRY_CAST(\(q) AS TIMESTAMPTZ) AS \(q)")
            default:
                parts.append(q)
            }
            if domainLabels, let cases = codedValueCases(field) {
                parts.append("CASE \(q) \(cases) END AS \(StagingDatabase.quote(field.name + "_label"))")
            }
        }
        return parts.joined(separator: ", ")
    }

    static func codedValueCases(_ field: FieldRecord) -> String? {
        guard let json = field.domainJSON, let data = json.data(using: .utf8),
              let domain = try? JSONDecoder().decode(JSONValue.self, from: data),
              domain["type"]?.stringValue == "codedValue",
              let values = domain["codedValues"]?.arrayValue, !values.isEmpty else { return nil }
        let whens = values.compactMap { v -> String? in
            guard let name = v["name"]?.stringValue, let code = v["code"] else { return nil }
            let literal: String
            switch code {
            case .number(let d): literal = d == d.rounded() ? String(Int64(d)) : String(d)
            case .string(let s): literal = "'" + escape(s) + "'"
            default: return nil
            }
            return "WHEN \(literal) THEN '\(escape(name))'"
        }
        return whens.isEmpty ? nil : whens.joined(separator: " ")
    }

    /// GeoParquet 1.1 `geo` metadata for the `geometry` column.
    static func geoMetadata(_ staging: StagingDatabase, outWkid: Int) throws -> String {
        var column: [String: Any] = ["encoding": "WKB", "geometry_types": staging.geometryTypes.sorted()]
        if let bbox = staging.bbox { column["bbox"] = [bbox.minX, bbox.minY, bbox.maxX, bbox.maxY] }
        if let projjson = try projjson(staging, wkid: outWkid),
           let data = projjson.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
            column["crs"] = object
        }
        let geo: [String: Any] = ["version": "1.1.0", "primary_column": "geometry", "columns": ["geometry": column]]
        let data = try JSONSerialization.data(withJSONObject: geo, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// PROJJSON for an EPSG code from DuckDB's CRS registry; nil when unknown.
    static func projjson(_ staging: StagingDatabase, wkid: Int) throws -> String? {
        try staging.run("SELECT projjson FROM duckdb_coordinate_systems() WHERE auth_name = 'EPSG' AND auth_code = ? LIMIT 1;",
                        [.string(String(wkid))]).rows.first?.first?.stringValue
    }

    // MARK: - From a stored GeoParquet

    /// Re-exports a stored GeoParquet to GeoJSON or CSV. `sourceWkid` is the file's spatial
    /// reference (the download's `outWkid`); GeoJSON is reprojected to WGS 84 from it.
    public static func reexport(parquet: URL, sourceWkid: Int, to url: URL, format: ExportFormat,
                                overwrite: Bool) throws -> ExportResult {
        guard format != .geoParquet else { throw ExportError.unsupportedFormat(format) }
        guard FileManager.default.fileExists(atPath: parquet.path) else { throw ExportError.missingSource(parquet.path) }
        try prepare(url, overwrite: overwrite)
        let db = try DuckDB()
        try db.run("INSTALL spatial;")
        try db.run("LOAD spatial;")
        try db.run("SET geometry_always_xy = true;")
        let source = "read_parquet('\(escape(parquet.path))')"
        var attributes = [String]()
        var geometryColumn: String?
        for row in try db.run("DESCRIBE SELECT * FROM \(source);").rows {
            guard let name = row[0].stringValue, let type = row[1].stringValue else { continue }
            let q = StagingDatabase.quote(name)
            if type.hasPrefix("GEOMETRY"), geometryColumn == nil {
                geometryColumn = q
            } else if type == "UUID" {
                attributes.append("\(q)::VARCHAR AS \(q)")
            } else {
                attributes.append(q)
            }
        }
        let geometry: String
        switch format {
        case .geoJSON: geometry = geometryColumn.map { wgs84($0, from: sourceWkid) } ?? "NULL::GEOMETRY"
        case .csv: geometry = geometryColumn.map { "ST_AsText(\($0))" } ?? "NULL::VARCHAR"
        case .geoParquet, .png, .geoTIFF: throw ExportError.unsupportedFormat(format)
        }
        let select = (attributes + ["\(geometry) AS geometry"]).joined(separator: ", ") + " FROM \(source)"
        try db.run(format == .geoJSON ? geoJSONCopy(select: select, to: url) : csvCopy(select: select, to: url))
        let count = Int64(try db.run("SELECT count(*) FROM \(source);").scalarString ?? "0") ?? 0
        var invalid: Int64 = 0
        if let g = geometryColumn {
            invalid = Int64(try db.run("SELECT count(*) FROM \(source) WHERE \(g) IS NOT NULL AND NOT ST_IsValid(\(g));").scalarString ?? "0") ?? 0
        }
        let (hash, bytes) = try hashFile(at: url)
        return ExportResult(path: url.path, sha256: hash, bytes: bytes, featureCount: count, invalidGeometries: invalid)
    }

    // MARK: - Shared

    /// Refuses to overwrite without consent (SPEC §5.7) and makes the output directory.
    static func prepare(_ url: URL, overwrite: Bool) throws {
        if FileManager.default.fileExists(atPath: url.path), !overwrite { throw ExportError.outputExists(url.path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// `expr` reprojected to WGS 84 from `wkid`, or as is when it already is.
    static func wgs84(_ expr: String, from wkid: Int) -> String {
        wkid == 4326 ? expr : "ST_Transform(\(expr), 'EPSG:\(wkid)', 'EPSG:4326', always_xy := true)"
    }

    /// GDAL's GeoJSON driver, RFC 7946 (WGS 84, 7 decimals, right-hand rule).
    static func geoJSONCopy(select: String, to url: URL) -> String {
        "COPY (SELECT \(select)) TO '\(escape(url.path))' WITH (FORMAT gdal, DRIVER 'GeoJSON', LAYER_CREATION_OPTIONS 'RFC7946=YES', SRS 'EPSG:4326');"
    }

    static func csvCopy(select: String, to url: URL) -> String {
        "COPY (SELECT \(select)) TO '\(escape(url.path))' (FORMAT CSV, HEADER true);"
    }

    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

    static func hashFile(at url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
            total += Int64(chunk.count)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, total)
    }
}
