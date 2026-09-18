import Foundation

/// Writes OGC WKB (little-endian, ISO Z/M type codes) from Esri geometry (SPEC §5.6).
///
/// Polylines with one path become LINESTRING, several MULTILINESTRING. Polygons follow the
/// Esri ring convention: clockwise rings are exteriors, anticlockwise are holes; each hole is
/// assigned to the exterior that contains its first vertex; several exteriors become a
/// MULTIPOLYGON. A hole no exterior contains is promoted to an exterior rather than dropped.
public enum WKBWriter {
    public enum GeometryKind: String, Sendable {
        case point = "Point", multiPoint = "MultiPoint", lineString = "LineString", multiLineString = "MultiLineString",
             polygon = "Polygon", multiPolygon = "MultiPolygon"

        var code: UInt32 {
            switch self {
            case .point: 1
            case .lineString: 2
            case .polygon: 3
            case .multiPoint: 4
            case .multiLineString: 5
            case .multiPolygon: 6
            }
        }
    }

    public struct Encoded: Sendable, Equatable {
        public let bytes: [UInt8]
        public let kind: GeometryKind
        /// The GeoParquet `geometry_types` name, e.g. `Polygon Z`.
        public let typeName: String
    }

    /// Encodes `geometry`. `hasZ` / `hasM` say what the third and fourth coordinates mean
    /// (Esri sends Z before M; a layer with M only puts M third).
    public static func encode(_ geometry: EsriGeometry, hasZ: Bool, hasM: Bool) -> Encoded {
        var out = Writer(hasZ: hasZ, hasM: hasM)
        let kind: GeometryKind
        switch geometry {
        case .point(let c):
            kind = .point
            out.header(kind)
            out.coordinate(c)
        case .multipoint(let points):
            kind = .multiPoint
            out.header(kind)
            out.u32(UInt32(points.count))
            for p in points {
                out.header(.point)
                out.coordinate(p)
            }
        case .polyline(let paths):
            if paths.count == 1 {
                kind = .lineString
                out.header(kind)
                out.ring(paths[0])
            } else {
                kind = .multiLineString
                out.header(kind)
                out.u32(UInt32(paths.count))
                for path in paths {
                    out.header(.lineString)
                    out.ring(path)
                }
            }
        case .polygon(let rings):
            let polygons = assemble(rings: rings)
            if polygons.count == 1 {
                kind = .polygon
                out.header(kind)
                out.polygon(polygons[0])
            } else {
                kind = .multiPolygon
                out.header(kind)
                out.u32(UInt32(polygons.count))
                for polygon in polygons {
                    out.header(.polygon)
                    out.polygon(polygon)
                }
            }
        case .envelope(let xmin, let ymin, let xmax, let ymax):
            kind = .polygon
            out.header(kind)
            out.polygon([[[xmin, ymin], [xmax, ymin], [xmax, ymax], [xmin, ymax], [xmin, ymin]]])
        }
        let suffix = hasZ && hasM ? " ZM" : (hasZ ? " Z" : (hasM ? " M" : ""))
        return Encoded(bytes: out.bytes, kind: kind, typeName: kind.rawValue + suffix)
    }

    // MARK: - Ring assembly

    /// Signed area by the shoelace formula (positive = anticlockwise in a y-up frame).
    public static func signedArea(_ ring: [[Double]]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            sum += a[0] * b[1] - b[0] * a[1]
        }
        return sum / 2
    }

    /// Ray casting, on XY only.
    public static func contains(_ ring: [[Double]], _ point: [Double]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1]
            if (yi > point[1]) != (yj > point[1]) {
                let x = (xj - xi) * (point[1] - yi) / (yj - yi) + xi
                if point[0] < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Groups Esri rings into polygons: each an exterior followed by its holes.
    public static func assemble(rings: [[[Double]]]) -> [[[[Double]]]] {
        var exteriors = [[[Double]]]()
        var holes = [[[Double]]]()
        for ring in rings where ring.count >= 3 {
            let closed = ring.first == ring.last ? ring : ring + [ring[0]]
            if signedArea(closed) <= 0 { exteriors.append(closed) } else { holes.append(closed) }
        }
        if exteriors.isEmpty, !holes.isEmpty {
            // Wrong-way data: treat every ring as an exterior rather than lose it.
            return holes.map { [$0] }
        }
        var polygons = exteriors.map { [$0] }
        for hole in holes {
            if let index = exteriors.firstIndex(where: { contains($0, hole[0]) }) {
                polygons[index].append(hole)
            } else {
                polygons.append([hole])
            }
        }
        return polygons
    }

    // MARK: - Byte writer

    private struct Writer {
        let hasZ: Bool
        let hasM: Bool
        var bytes = [UInt8]()

        mutating func header(_ kind: GeometryKind) {
            bytes.append(1)   // little-endian
            var code = kind.code
            if hasZ { code += 1000 }
            if hasM { code += 2000 }
            u32(code)
        }

        mutating func u32(_ v: UInt32) {
            withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) }
        }

        mutating func double(_ v: Double) {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { bytes.append(contentsOf: $0) }
        }

        var dimensions: Int { 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0) }

        mutating func coordinate(_ c: [Double]) {
            for i in 0..<dimensions { double(i < c.count ? c[i] : .nan) }
        }

        mutating func ring(_ points: [[Double]]) {
            u32(UInt32(points.count))
            for p in points { coordinate(p) }
        }

        mutating func polygon(_ rings: [[[Double]]]) {
            u32(UInt32(rings.count))
            for r in rings { ring(r) }
        }
    }
}
