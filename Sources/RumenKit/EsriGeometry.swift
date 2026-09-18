import Foundation

/// An Esri JSON geometry as returned by `query` (`f=json`). Coordinates keep their arity
/// (2 = XY, 3 = XYZ or XYM depending on the layer, 4 = XYZM); conversion to WKB is M4.
public enum EsriGeometry: Sendable, Equatable {
    case point([Double])
    case multipoint([[Double]])
    case polyline(paths: [[[Double]]])
    case polygon(rings: [[[Double]]])
    case envelope(xmin: Double, ymin: Double, xmax: Double, ymax: Double)

    /// Parses the `geometry` object of a feature. Nil for an absent or empty geometry (Esri
    /// emits `"x": "NaN"` or empty ring lists for empty geometries).
    public init?(json: JSONValue?) {
        guard let json, case .object(let o) = json else { return nil }
        if let x = o["x"]?.doubleValue, let y = o["y"]?.doubleValue {
            var coords = [x, y]
            if let z = o["z"]?.doubleValue { coords.append(z) }
            if let m = o["m"]?.doubleValue { coords.append(m) }
            self = .point(coords)
        } else if let points = o["points"]?.arrayValue {
            let parsed = points.compactMap(Self.coordinate)
            guard !parsed.isEmpty else { return nil }
            self = .multipoint(parsed)
        } else if let paths = o["paths"]?.arrayValue {
            let parsed = paths.compactMap(Self.part).filter { !$0.isEmpty }
            guard !parsed.isEmpty else { return nil }
            self = .polyline(paths: parsed)
        } else if let rings = o["rings"]?.arrayValue {
            let parsed = rings.compactMap(Self.part).filter { !$0.isEmpty }
            guard !parsed.isEmpty else { return nil }
            self = .polygon(rings: parsed)
        } else if let xmin = o["xmin"]?.doubleValue, let ymin = o["ymin"]?.doubleValue,
                  let xmax = o["xmax"]?.doubleValue, let ymax = o["ymax"]?.doubleValue {
            self = .envelope(xmin: xmin, ymin: ymin, xmax: xmax, ymax: ymax)
        } else {
            return nil
        }
    }

    private static func coordinate(_ v: JSONValue) -> [Double]? {
        guard let a = v.arrayValue, a.count >= 2 else { return nil }
        let doubles = a.compactMap(\.doubleValue)
        return doubles.count == a.count ? doubles : nil
    }

    private static func part(_ v: JSONValue) -> [[Double]]? {
        guard let a = v.arrayValue else { return nil }
        return a.compactMap(coordinate)
    }

    public var vertexCount: Int {
        switch self {
        case .point: return 1
        case .multipoint(let p): return p.count
        case .polyline(let paths): return paths.reduce(0) { $0 + $1.count }
        case .polygon(let rings): return rings.reduce(0) { $0 + $1.count }
        case .envelope: return 2
        }
    }

    /// True when every coordinate has three or more values.
    public var hasZOrM: Bool {
        switch self {
        case .point(let c): return c.count >= 3
        case .multipoint(let p): return p.first.map { $0.count >= 3 } ?? false
        case .polyline(let paths): return paths.first?.first.map { $0.count >= 3 } ?? false
        case .polygon(let rings): return rings.first?.first.map { $0.count >= 3 } ?? false
        case .envelope: return false
        }
    }

    /// A one-line rendering for a grid cell: WKT for points, a shape summary otherwise.
    public var summary: String {
        func f(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...6)).grouping(.never)) }
        switch self {
        case .point(let c):
            return "POINT (" + c.prefix(2).map(f).joined(separator: " ") + ")"
        case .multipoint(let p):
            return "MULTIPOINT, \(p.count) point\(p.count == 1 ? "" : "s")"
        case .polyline(let paths):
            return "POLYLINE, \(paths.count) path\(paths.count == 1 ? "" : "s"), \(vertexCount) vertices"
        case .polygon(let rings):
            return "POLYGON, \(rings.count) ring\(rings.count == 1 ? "" : "s"), \(vertexCount) vertices"
        case .envelope(let xmin, let ymin, let xmax, let ymax):
            return "ENVELOPE (\(f(xmin)) \(f(ymin)), \(f(xmax)) \(f(ymax)))"
        }
    }
}
