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

    public func union(_ other: BoundingBox) -> BoundingBox {
        BoundingBox(minX: min(minX, other.minX), minY: min(minY, other.minY),
                    maxX: max(maxX, other.maxX), maxY: max(maxY, other.maxY))
    }

    /// The union of `boxes`, ignoring world-sized ones (a server default, not data) unless
    /// nothing else is there.
    public static func union(of boxes: [BoundingBox]) -> BoundingBox? {
        let real = boxes.filter { !$0.isWorldSized }
        let boxes = real.isEmpty ? boxes : real
        guard var result = boxes.first else { return nil }
        for box in boxes.dropFirst() { result = result.union(box) }
        return result
    }

    /// Clamped to valid lon/lat so a slightly-out-of-range PROJ result cannot break layout.
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
