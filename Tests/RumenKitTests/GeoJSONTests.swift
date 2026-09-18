import XCTest
import Foundation
import RumenKit

final class GeoJSONTests: XCTestCase {

    private func parse(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func testPointAndLines() throws {
        XCTAssertEqual(GeoJSON.geometry(.point([-1.5, 51.25])), #"{"type":"Point","coordinates":[-1.5,51.25]}"#)
        XCTAssertEqual(GeoJSON.geometry(.point([1, 2, 3])), #"{"type":"Point","coordinates":[1,2]}"#, "XY only")
        XCTAssertEqual(GeoJSON.geometry(.polyline(paths: [[[0, 0], [1, 1]]])), #"{"type":"LineString","coordinates":[[0,0],[1,1]]}"#)
        let multi = try parse(GeoJSON.geometry(.polyline(paths: [[[0, 0], [1, 1]], [[2, 2], [3, 3]]])))
        XCTAssertEqual(multi["type"] as? String, "MultiLineString")
        XCTAssertEqual(GeoJSON.geometry(.multipoint([[1, 2], [3, 4]])), #"{"type":"MultiPoint","coordinates":[[1,2],[3,4]]}"#)
    }

    func testPolygonsAssembleLikeWKB() throws {
        let exterior: [[Double]] = [[0, 0], [0, 10], [10, 10], [10, 0], [0, 0]]
        let hole: [[Double]] = [[2, 2], [4, 2], [4, 4], [2, 4], [2, 2]]
        let island: [[Double]] = [[20, 20], [20, 25], [25, 25], [25, 20], [20, 20]]
        let single = try parse(GeoJSON.geometry(.polygon(rings: [exterior, hole])))
        XCTAssertEqual(single["type"] as? String, "Polygon")
        XCTAssertEqual((single["coordinates"] as? [[[Double]]])?.count, 2, "exterior + hole")
        let multi = try parse(GeoJSON.geometry(.polygon(rings: [hole, island, exterior])))
        XCTAssertEqual(multi["type"] as? String, "MultiPolygon")
        XCTAssertEqual((multi["coordinates"] as? [[[[Double]]]])?.count, 2)
        let unclosed = try parse(GeoJSON.geometry(.polygon(rings: [[[0, 0], [0, 1], [1, 1]]])))
        XCTAssertEqual(((unclosed["coordinates"] as? [[[Double]]])?.first)?.count, 4, "ring closed")
    }

    func testFeatureCollectionAndBox() throws {
        let f = GeoJSON.feature(.point([1, 2]), properties: ["name": "a \"quoted\" name", "id": "7"])
        let parsed = try parse(f)
        XCTAssertEqual(parsed["type"] as? String, "Feature")
        XCTAssertEqual((parsed["properties"] as? [String: String])?["name"], "a \"quoted\" name")
        let fc = try parse(GeoJSON.featureCollection([f, GeoJSON.feature(.point([3, 4]))]))
        XCTAssertEqual((fc["features"] as? [Any])?.count, 2)
        let box = try parse(GeoJSON.box(BoundingBox(minX: -1, minY: 50, maxX: 1, maxY: 52)))
        XCTAssertEqual(box["type"] as? String, "Polygon")
        XCTAssertEqual(((box["coordinates"] as? [[[Double]]])?.first)?.count, 5)
    }

    func testRealPolygonsFromFixture() throws {
        let page = FeaturePage(json: try ArcGISJSON.decode(FeatureSet.self, from: Fixtures.data("s6-census-l3-features.json")))
        for feature in page.features {
            let text = GeoJSON.geometry(try XCTUnwrap(feature.geometry))
            let parsed = try parse(text)
            XCTAssertTrue(["Polygon", "MultiPolygon"].contains(parsed["type"] as? String ?? ""))
        }
    }
}
