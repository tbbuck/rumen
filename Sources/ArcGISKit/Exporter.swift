import Foundation
import CryptoKit
import DuckDBKit

public enum ExportError: Error, CustomStringConvertible, Equatable {
    case outputExists(String)
    case unsupportedFormat(ExportFormat)

    public var description: String {
        switch self {
        case .outputExists(let p): return "output file already exists: \(p)"
        case .unsupportedFormat(let f): return "\(f.label) export is not available yet"
        }
    }
}

public struct ExportResult: Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let bytes: Int64
    public let featureCount: Int64
    public let invalidGeometries: Int64
}

/// Writes the staging table to the chosen format (SPEC §5.7). GeoParquet: the WKB column as
/// `geometry` with our own `geo` metadata — geometry types, bbox, and the CRS as PROJJSON
/// from DuckDB's registry — because DuckDB's writer omits the CRS.
public enum Exporter {
    /// Sanitised `<dir>/<server>/<service>/<layer>.<ext>`.
    public static func outputPath(directory: URL, server: ServerRecord, service: ServiceRecord, layer: LayerRecord,
                                  format: ExportFormat) -> URL {
        directory.appendingPathComponent(component(server.friendlyName))
            .appendingPathComponent(component(service.name))
            .appendingPathComponent(component(layer.name))
            .appendingPathExtension(format.fileExtension)
    }

    static func component(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if out.isEmpty || out == "." || out == ".." { out = "_" }
        return out
    }

    public static func export(_ staging: StagingDatabase, to url: URL, format: ExportFormat, outWkid: Int,
                              domainLabels: Bool, overwrite: Bool) throws -> ExportResult {
        guard format == .geoParquet else { throw ExportError.unsupportedFormat(format) }
        if FileManager.default.fileExists(atPath: url.path), !overwrite { throw ExportError.outputExists(url.path) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let selectList = try columns(staging, domainLabels: domainLabels)
        let orderBy = staging.oidField.map { " ORDER BY \(StagingDatabase.quote($0))" } ?? ""
        let invalid = try staging.countInvalidGeometries()
        let metadata = try geoMetadata(staging, outWkid: outWkid)
        let sql = """
            COPY (SELECT \(selectList), geom_wkb AS geometry FROM features\(orderBy))
            TO '\(escape(url.path))' (FORMAT PARQUET, KV_METADATA {geo: '\(escape(metadata))'});
            """
        try staging.run(sql)

        let count = try staging.rowCount()
        let (hash, bytes) = try hashFile(at: url)
        return ExportResult(path: url.path, sha256: hash, bytes: bytes, featureCount: count, invalidGeometries: invalid)
    }

    /// The exported columns: staged types with GUIDs cast to UUID, time-ish strings cast to
    /// their types, and optional `<field>_label` columns decoded from coded-value domains.
    static func columns(_ staging: StagingDatabase, domainLabels: Bool) throws -> String {
        var parts = [String]()
        for field in staging.stagedFields {
            let q = StagingDatabase.quote(field.name)
            switch field.esriType {
            case .guid, .globalID:
                parts.append("TRY_CAST(trim(\(q), '{}') AS UUID) AS \(q)")
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
