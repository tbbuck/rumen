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
