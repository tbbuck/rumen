import Foundation

/// The map's visible area in WGS 84 plus its pixel size, as the page reports it.
public struct MapViewport: Sendable, Equatable {
    public var west: Double
    public var south: Double
    public var east: Double
    public var north: Double
    public var width: Double
    public var height: Double
    public var zoom: Double

    public init(west: Double, south: Double, east: Double, north: Double, width: Double, height: Double, zoom: Double = 0) {
        self.west = west
        self.south = south
        self.east = east
        self.north = north
        self.width = width
        self.height = height
        self.zoom = zoom
    }

    /// Web Mercator y for a latitude (radians-free form), clamped to the projection's limits.
    public static func mercator(_ lat: Double) -> Double {
        let clamped = max(-85.05112878, min(85.05112878, lat))
        return log(tan(.pi / 4 + clamped * .pi / 360))
    }

    /// Pixel x for a longitude in this viewport (north-up Mercator: linear in longitude).
    public func x(forLongitude lon: Double) -> Double {
        guard east > west else { return 0 }
        return (lon - west) / (east - west) * width
    }

    /// Pixel y (down) for a latitude.
    public func y(forLatitude lat: Double) -> Double {
        let top = Self.mercator(north), bottom = Self.mercator(south)
        guard top > bottom else { return 0 }
        return (top - Self.mercator(lat)) / (top - bottom) * height
    }
}

/// One tick on a sheet margin: a pixel position along the edge and its label.
public struct GraticuleTick: Sendable, Equatable {
    public let position: Double
    public let label: String
    public let value: Double
}

/// A graticule for the map sheet (UI-SPEC: SheetMargins): nice-stepped lines with ticks every
/// second line, in lon/lat or, via a transform, in the layer's projected reference.
public struct Graticule: Sendable, Equatable {
    public let step: Double
    /// Pixel positions along the top/bottom edge with labels (eastings / longitudes).
    public let xTicks: [GraticuleTick]
    /// Pixel positions down the left edge with labels (northings / latitudes).
    public let yTicks: [GraticuleTick]
    /// GeoJSON FeatureCollection of the grid lines in WGS 84, for the map page.
    public let linesGeoJSON: String
    public let isProjected: Bool

    /// Nice steps: 1, 2, 5 × 10ⁿ; picks the largest that gives at least `minLines` lines.
    public static func niceStep(span: Double, minLines: Int = 4) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let raw = span / Double(minLines)
        let magnitude = pow(10, floor(log10(raw)))
        for factor in [5.0, 2.0, 1.0] {
            let candidate = magnitude * factor
            if candidate <= raw { return candidate }
        }
        return magnitude / 2
    }

    /// Lon/lat graticule: lines every `step` degrees across the viewport.
    public static func geographic(_ v: MapViewport) -> Graticule {
        let step = niceStep(span: max(v.east - v.west, (v.north - v.south)))
        var xTicks = [GraticuleTick](), yTicks = [GraticuleTick]()
        var lines = [String]()
        var index = 0
        var lon = (v.west / step).rounded(.down) * step
        while lon <= v.east {
            if lon >= v.west {
                lines.append(GeoJSON.feature(.polyline(paths: [[[lon, v.south], [lon, v.north]]])))
                if index % 2 == 0 { xTicks.append(GraticuleTick(position: v.x(forLongitude: lon), label: degrees(wrap(lon), step), value: lon)) }
                index += 1
            }
            lon += step
        }
        index = 0
        var lat = (v.south / step).rounded(.down) * step
        while lat <= v.north {
            if lat >= v.south {
                lines.append(GeoJSON.feature(.polyline(paths: [[[v.west, lat], [v.east, lat]]])))
                if index % 2 == 0 { yTicks.append(GraticuleTick(position: v.y(forLatitude: lat), label: degrees(lat, step), value: lat)) }
                index += 1
            }
            lat += step
        }
        return Graticule(step: step, xTicks: xTicks, yTicks: yTicks, linesGeoJSON: GeoJSON.featureCollection(lines), isProjected: false)
    }

    /// Projected graticule: eastings and northings in the layer's units. `toNative` maps
    /// lon/lat pairs to native, `toGeographic` the reverse (both batch calls). Lines are
    /// sampled so they curve correctly on the Mercator map.
    public static func projected(_ v: MapViewport,
                                 toNative: @Sendable ([(Double, Double)]) async throws -> [(Double, Double)],
                                 toGeographic: @Sendable ([(Double, Double)]) async throws -> [(Double, Double)]) async throws -> Graticule {
        // Native bounds from the viewport corners and edge midpoints.
        let corners = try await toNative([(v.west, v.south), (v.east, v.south), (v.east, v.north), (v.west, v.north),
                                          ((v.west + v.east) / 2, v.south), ((v.west + v.east) / 2, v.north),
                                          (v.west, (v.south + v.north) / 2), (v.east, (v.south + v.north) / 2)])
        guard corners.allSatisfy({ $0.0.isFinite && $0.1.isFinite }) else { return geographic(v) }
        let minE = corners.map(\.0).min()!, maxE = corners.map(\.0).max()!
        let minN = corners.map(\.1).min()!, maxN = corners.map(\.1).max()!
        let step = niceStep(span: max(maxE - minE, maxN - minN))
        let samples = 12
        var lines = [String]()
        var request = [(Double, Double)]()
        var eastings = [Double](), northings = [Double]()
        var e = (minE / step).rounded(.down) * step
        while e <= maxE { if e >= minE { eastings.append(e) }; e += step }
        var n = (minN / step).rounded(.down) * step
        while n <= maxN { if n >= minN { northings.append(n) }; n += step }
        guard eastings.count + northings.count <= 400 else { return geographic(v) }
        for e in eastings { for i in 0...samples { request.append((e, minN + (maxN - minN) * Double(i) / Double(samples))) } }
        for n in northings { for i in 0...samples { request.append((minE + (maxE - minE) * Double(i) / Double(samples), n)) } }
        // Tick anchors: eastings along the viewport's mid northing, northings along the mid easting.
        let midN = (minN + maxN) / 2, midE = (minE + maxE) / 2
        for e in eastings { request.append((e, midN)) }
        for n in northings { request.append((midE, n)) }
        let geo = try await toGeographic(request)
        var cursor = 0
        func take(_ count: Int) -> [(Double, Double)] { defer { cursor += count }; return Array(geo[cursor..<cursor + count]) }
        for _ in eastings { lines.append(GeoJSON.feature(.polyline(paths: [take(samples + 1).map { [$0.0, $0.1] }]))) }
        for _ in northings { lines.append(GeoJSON.feature(.polyline(paths: [take(samples + 1).map { [$0.0, $0.1] }]))) }
        var xTicks = [GraticuleTick](), yTicks = [GraticuleTick]()
        for (i, e) in eastings.enumerated() {
            let p = take(1)[0]
            if i % 2 == 0, p.0 >= v.west, p.0 <= v.east { xTicks.append(GraticuleTick(position: v.x(forLongitude: p.0), label: metres(e), value: e)) }
        }
        for (i, n) in northings.enumerated() {
            let p = take(1)[0]
            if i % 2 == 0, p.1 >= v.south, p.1 <= v.north { yTicks.append(GraticuleTick(position: v.y(forLatitude: p.1), label: metres(n), value: n)) }
        }
        return Graticule(step: step, xTicks: xTicks, yTicks: yTicks, linesGeoJSON: GeoJSON.featureCollection(lines), isProjected: true)
    }

    /// Longitudes past the antimeridian, as MapLibre reports them when panned around, back into [-180, 180].
    public static func wrap(_ lon: Double) -> Double {
        var w = (lon + 180).truncatingRemainder(dividingBy: 360)
        if w < 0 { w += 360 }
        return w - 180
    }

    static func degrees(_ v: Double, _ step: Double) -> String {
        let decimals = max(0, Int(ceil(-log10(step))))
        return v.formatted(.number.precision(.fractionLength(decimals)).grouping(.never)) + "°"
    }

    /// Projected units, in km when the step is a kilometre or more: `345 000` → `345 km`.
    static func metres(_ v: Double) -> String {
        if abs(v) >= 1000, v.truncatingRemainder(dividingBy: 1000) == 0 {
            return (v / 1000).formatted(.number.grouping(.automatic)) + " km"
        }
        return v.formatted(.number.precision(.fractionLength(0)).grouping(.automatic))
    }
}
