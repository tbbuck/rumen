import XCTest
import Foundation
import RumenKit
import DuckDBKit

final class MapSupportTests: XCTestCase {

    func testNiceSteps() {
        XCTAssertEqual(Graticule.niceStep(span: 10), 2)
        XCTAssertEqual(Graticule.niceStep(span: 4), 1)
        XCTAssertEqual(Graticule.niceStep(span: 0.35), 0.05)
        XCTAssertEqual(Graticule.niceStep(span: 100_000), 20_000)
        XCTAssertEqual(Graticule.niceStep(span: 0), 1)
    }

    func testGeographicGraticule() throws {
        let v = MapViewport(west: -3, south: 50, east: 1, north: 53, width: 800, height: 600)
        let g = Graticule.geographic(v)
        XCTAssertEqual(g.step, 1)
        XCTAssertFalse(g.isProjected)
        XCTAssertEqual(g.xTicks.map(\.value), [-3, -1, 1], "every second line")
        XCTAssertEqual(g.xTicks.map(\.label), ["-3°", "-1°", "1°"])
        XCTAssertEqual(g.xTicks[0].position, 0, accuracy: 0.01)
        XCTAssertEqual(g.xTicks[2].position, 800, accuracy: 0.01)
        XCTAssertEqual(g.yTicks.map(\.value), [50, 52])
        XCTAssertEqual(g.yTicks[0].position, 600, accuracy: 0.01, "south edge is the bottom")
        XCTAssertLessThan(g.yTicks[1].position, 300, "Mercator stretches northwards")
        let fc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(g.linesGeoJSON.utf8)) as? [String: Any])
        XCTAssertEqual((fc["features"] as? [Any])?.count, 5 + 4, "5 meridians, 4 parallels")
    }

    func testProjectedGraticuleWithIdentityTransforms() async throws {
        // Identity "projection": eastings are longitudes × 1000 so steps land in the metre formatter.
        let v = MapViewport(west: -3, south: 50, east: 1, north: 53, width: 800, height: 600)
        let g = try await Graticule.projected(v, toNative: { $0.map { ($0.0 * 100_000, $0.1 * 100_000) } },
                                              toGeographic: { $0.map { ($0.0 / 100_000, $0.1 / 100_000) } })
        XCTAssertTrue(g.isProjected)
        XCTAssertEqual(g.step, 100_000)
        XCTAssertEqual(g.xTicks.map(\.label), ["-300 km", "-100 km", "100 km"])
        XCTAssertEqual(g.yTicks.first?.label, "5,000 km")
        let fc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(g.linesGeoJSON.utf8)) as? [String: Any])
        XCTAssertEqual((fc["features"] as? [Any])?.count, 9)
    }

    func testViewportMaths() {
        let v = MapViewport(west: 0, south: 0, east: 10, north: 10, width: 100, height: 100)
        XCTAssertEqual(v.x(forLongitude: 5), 50)
        XCTAssertEqual(v.y(forLatitude: 10), 0)
        XCTAssertEqual(v.y(forLatitude: 0), 100)
        XCTAssertGreaterThan(v.y(forLatitude: 5), 50, "Mercator stretches away from the equator, so the mid-latitude sits below the pixel centre")
        XCTAssertEqual(MapViewport.mercator(89.9999), MapViewport.mercator(85.05112878), "clamped")
    }

    func testStoredSampleAndTransform() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()

        // A tiny GeoParquet written by DuckDB itself.
        let parquet = scratch.appendingPathComponent("t.parquet").path
        let duck = try DuckDB()
        try duck.run("INSTALL spatial;")
        try duck.run("LOAD spatial;")
        try duck.run("""
            COPY (SELECT i AS id, ST_Point(-1.0 + i * 0.1, 51.0) AS geometry FROM range(10) t(i))
            TO '\(parquet)' (FORMAT PARQUET);
            """)
        let all = try await db.storedSample(path: parquet)
        XCTAssertEqual(all.total, 10)
        XCTAssertEqual(all.shown, 10)
        XCTAssertFalse(all.simplified)
        XCTAssertTrue(all.geoJSON.contains(#""type":"Point""#))
        let some = try await db.storedSample(path: parquet, whereClause: "id >= 7", limit: 2)
        XCTAssertEqual(some.total, 3)
        XCTAssertEqual(some.shown, 2)
        await XCTAssertThrowsErrorAsync(try await db.storedSample(path: parquet, whereClause: "nope = 1")) { error in
            XCTAssertTrue(String(describing: error).contains("nope"), String(describing: error))
        }

        let bng = try await db.transform([(-0.1276, 51.5074), (-3.1883, 55.9533)], from: 4326, to: 27700)
        XCTAssertEqual(bng[0].0, 530_000, accuracy: 1500)   // London
        XCTAssertEqual(bng[0].1, 180_000, accuracy: 1500)
        XCTAssertEqual(bng[1].1, 673_000, accuracy: 2000)   // Edinburgh
        let back = try await db.transform(bng, from: 27700, to: 4326)
        XCTAssertEqual(back[0].0, -0.1276, accuracy: 0.001)
        XCTAssertEqual(back[1].1, 55.9533, accuracy: 0.001)
        let same = try await db.transform([(1, 2)], from: 4326, to: 4326)
        XCTAssertEqual(same[0].0, 1)
    }
}

extension MapSupportTests {
    func testLongitudeWrapping() {
        XCTAssertEqual(Graticule.wrap(-200), 160)
        XCTAssertEqual(Graticule.wrap(200), -160)
        XCTAssertEqual(Graticule.wrap(-180), -180)
        XCTAssertEqual(Graticule.wrap(180), -180)
        XCTAssertEqual(Graticule.wrap(45), 45)
        let v = MapViewport(west: -200, south: 20, east: -100, north: 60, width: 1000, height: 400)
        let g = Graticule.geographic(v)
        XCTAssertEqual(g.xTicks.first?.label, "160°")
    }
}
