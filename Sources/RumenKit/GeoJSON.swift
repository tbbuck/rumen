import Foundation

/// GeoJSON text from Esri geometry, for the map (SPEC §5.9). Coordinates are written as they
/// are (the caller asks the server for WGS 84); rings are assembled like WKB.
public enum GeoJSON {
    public static func geometry(_ g: EsriGeometry) -> String {
        switch g {
        case .point(let c):
            return #"{"type":"Point","coordinates":\#(position(c))}"#
        case .multipoint(let points):
            return #"{"type":"MultiPoint","coordinates":[\#(points.map(position).joined(separator: ","))]}"#
        case .polyline(let paths):
            if paths.count == 1 {
                return #"{"type":"LineString","coordinates":\#(line(paths[0]))}"#
            }
            return #"{"type":"MultiLineString","coordinates":[\#(paths.map(line).joined(separator: ","))]}"#
        case .polygon(let rings):
            let polygons = WKBWriter.assemble(rings: rings)
            if polygons.count == 1 {
                return #"{"type":"Polygon","coordinates":\#(polygon(polygons[0]))}"#
            }
            return #"{"type":"MultiPolygon","coordinates":[\#(polygons.map(polygon).joined(separator: ","))]}"#
        case .envelope(let xmin, let ymin, let xmax, let ymax):
            return #"{"type":"Polygon","coordinates":[[[\#(n(xmin)),\#(n(ymin))],[\#(n(xmax)),\#(n(ymin))],[\#(n(xmax)),\#(n(ymax))],[\#(n(xmin)),\#(n(ymax))],[\#(n(xmin)),\#(n(ymin))]]]}"#
        }
    }

    /// A Feature with string properties.
    public static func feature(_ g: EsriGeometry, properties: [String: String] = [:]) -> String {
        let props = properties.keys.sorted().map { "\(quote($0)):\(quote(properties[$0]!))" }.joined(separator: ",")
        return #"{"type":"Feature","properties":{\#(props)},"geometry":\#(geometry(g))}"#
    }

    public static func featureCollection(_ features: [String]) -> String {
        #"{"type":"FeatureCollection","features":[\#(features.joined(separator: ","))]}"#
    }

    /// A dashed-box style rectangle for an extent.
    public static func box(_ b: BoundingBox) -> String {
        geometry(.envelope(xmin: b.minX, ymin: b.minY, xmax: b.maxX, ymax: b.maxY))
    }

    static func n(_ v: Double) -> String {
        guard v.isFinite else { return "0" }
        return v.formatted(.number.precision(.fractionLength(0...7)).grouping(.never))
    }
    static func position(_ c: [Double]) -> String { "[\(c.prefix(2).map(n).joined(separator: ","))]" }
    static func line(_ pts: [[Double]]) -> String { "[\(pts.map(position).joined(separator: ","))]" }
    static func polygon(_ rings: [[[Double]]]) -> String { "[\(rings.map(line).joined(separator: ","))]" }
    static func quote(_ s: String) -> String {
        let data = (try? JSONEncoder().encode(s)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
