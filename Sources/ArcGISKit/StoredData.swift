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
            SELECT ST_AsGeoJSON(\(geometry)) FROM read_parquet('\(file)')\(whereSQL) LIMIT \(max(1, limit));
            """).rows
        let features = rows.compactMap { $0.first?.stringValue }.filter { !$0.isEmpty }
            .map { #"{"type":"Feature","properties":{},"geometry":\#($0)}"# }
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
