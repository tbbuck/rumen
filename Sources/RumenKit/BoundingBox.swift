import Foundation

/// An axis-aligned box in WGS 84 (lon/lat), the common frame for the tree's extent locators
/// and the map. Native-SR extents stay in `Extent`; this is always 4326.
public struct BoundingBox: Sendable, Equatable, Codable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static let world = BoundingBox(minX: -180, minY: -90, maxX: 180, maxY: 90)

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var centre: (x: Double, y: Double) { ((minX + maxX) / 2, (minY + maxY) / 2) }

    /// True when the box covers most of the globe — a sign the extent is a default, not data.
    public var isWorldSized: Bool { width >= 300 && height >= 150 }

    /// No area (an empty layer reports 0,0,0,0) or not a number: nothing to draw or frame.
    public var isDegenerate: Bool {
        !(minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite) || width <= 0 || height <= 0
    }

    /// Looks like a server default rather than data: degenerate, world-sized, or spanning
    /// more of the globe than a single dataset plausibly does (150° of longitude, 100° of
    /// latitude). Such boxes never shape a frame; they still draw, clipped, when asked.
    public var isDefaultLike: Bool {
        isDegenerate || isWorldSized || width >= 150 || height >= 100 || huddlesAtNullIsland
    }

    /// Within a degree of 0,0: what a mislabelled or empty extent reprojects to, not data.
    public var huddlesAtNullIsland: Bool {
        abs(minX) < 1 && abs(maxX) < 1 && abs(minY) < 1 && abs(maxY) < 1
    }

    public func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(minX: min(minX, other.minX), minY: min(minY, other.minY),
                    maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    /// Where the bulk of `boxes` sits: the union ignoring default-looking ones (see
    /// `isDefaultLike`) unless nothing else is there, degenerate ones always, and, given five
    /// or more, the outliers whose centres fall in the outer tenth on either axis. A single
    /// service on another continent no longer squashes every other locator into a corner.
    public static func union(of boxes: [BoundingBox]) -> BoundingBox? {
        let usable = boxes.filter { !$0.isDegenerate }
        let real = usable.filter { !$0.isDefaultLike }
        var boxes = real.isEmpty ? usable : real
        if boxes.count >= 5 {
            let trim = max(1, boxes.count / 10)
            let xs = boxes.map(\.centre.x).sorted()
            let ys = boxes.map(\.centre.y).sorted()
            let xLow = xs[trim], xHigh = xs[xs.count - 1 - trim]
            let yLow = ys[trim], yHigh = ys[ys.count - 1 - trim]
            let kept = boxes.filter { $0.centre.x >= xLow && $0.centre.x <= xHigh && $0.centre.y >= yLow && $0.centre.y <= yHigh }
            if !kept.isEmpty { boxes = kept }
        }
        guard var result = boxes.first else { return nil }
        for box in boxes.dropFirst() { result = result.union(box) }
        return result
    }

    /// The WGS 84 box of an extent a server reported, when the extent is already in WGS 84
    /// degrees; nil for every other spatial reference, and for an empty extent.
    ///
    /// Nothing is reprojected. A crawl used to push every extent through PROJ to give each
    /// tree node a locator, at 10 ms a time and two a service: 80 seconds of a crawl of ONS,
    /// one at a time, for a 22 × 15 pixel box. A layer in a projected reference now simply has
    /// no box, and the map frames it from the features it draws.
    public static func wgs84(of extent: Extent?, wkid: Int?) -> BoundingBox? {
        guard let e = extent, let xmin = e.xmin, let ymin = e.ymin, let xmax = e.xmax, let ymax = e.ymax,
              let wkid = wkid ?? e.spatialReference?.effectiveWkid else { return nil }
        // Seen on ArcGIS Online: an extent in degrees tagged Web Mercator. Metre coordinates that
        // all fit inside lon/lat range would be a few hundred metres around Null Island, which no
        // real layer is, so such a box is read as degrees. Only for the Mercator family: an
        // unknown CRS must still come back as unknown.
        let webMercator: Set<Int> = [3857, 102100, 102113, 900913, 3785]
        let looksLikeDegrees = webMercator.contains(wkid)
            && abs(xmin) <= 180 && abs(xmax) <= 180 && abs(ymin) <= 90 && abs(ymax) <= 90
        guard wkid == 4326 || looksLikeDegrees else { return nil }
        return BoundingBox(minX: xmin, minY: ymin, maxX: xmax, maxY: ymax).clampedToWorld
    }

    /// Clamped to valid lon/lat so a slightly-out-of-range extent cannot break layout.
    public var clampedToWorld: BoundingBox {
        BoundingBox(minX: max(-180, minX), minY: max(-90, minY), maxX: min(180, maxX), maxY: min(90, maxY))
    }

    public var json: String {
        "{\"minX\":\(minX),\"minY\":\(minY),\"maxX\":\(maxX),\"maxY\":\(maxY)}"
    }

    public init?(json: String?) {
        guard let json, let data = json.data(using: .utf8),
              let box = try? JSONDecoder().decode(BoundingBox.self, from: data) else { return nil }
        self = box
    }
}
