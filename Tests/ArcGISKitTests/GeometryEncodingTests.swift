import XCTest
import Foundation
import ArcGISKit
import DuckDBKit

/// The download engine's decoders: PBF and JSON pages of the same features must agree, and
/// every geometry must become valid WKB that DuckDB's spatial extension reads back.
final class GeometryEncodingTests: XCTestCase {

    private static let spatial: DuckDB = {
        let db = try! DuckDB()
        try! db.run("INSTALL spatial;")
        try! db.run("LOAD spatial;")
        return db
    }()

    private func wkt(_ encoded: WKBWriter.Encoded) throws -> (text: String, valid: Bool, type: String) {
        let row = try Self.spatial.run(
            "SELECT ST_AsText(ST_GeomFromWKB(?)), ST_IsValid(ST_GeomFromWKB(?)), ST_GeometryType(ST_GeomFromWKB(?))::VARCHAR;",
            [.blob(encoded.bytes), .blob(encoded.bytes), .blob(encoded.bytes)]).rows[0]
        return (row[0].stringValue ?? "", row[1] == .bool(true), row[2].stringValue ?? "")
    }

    // MARK: - WKB

    func testPointLineAndMultiLine() throws {
        let point = try wkt(WKBWriter.encode(.point([1, 2]), hasZ: false, hasM: false))
        XCTAssertEqual(point.text, "POINT (1 2)")
        XCTAssertEqual(point.type, "POINT")
        let line = try wkt(WKBWriter.encode(.polyline(paths: [[[0, 0], [1, 1], [2, 0]]]), hasZ: false, hasM: false))
        XCTAssertEqual(line.text, "LINESTRING (0 0, 1 1, 2 0)")
        let multi = WKBWriter.encode(.polyline(paths: [[[0, 0], [1, 1]], [[5, 5], [6, 6]]]), hasZ: false, hasM: false)
        XCTAssertEqual(multi.kind, .multiLineString)
        XCTAssertEqual(try wkt(multi).text, "MULTILINESTRING ((0 0, 1 1), (5 5, 6 6))")
        let points = try wkt(WKBWriter.encode(.multipoint([[1, 2], [3, 4]]), hasZ: false, hasM: false))
        XCTAssertEqual(points.text, "MULTIPOINT (1 2, 3 4)")
        XCTAssertTrue([point, line, points].allSatisfy(\.valid))
    }

    func testPolygonWithHoleAndMultiPolygon() throws {
        // Esri convention: clockwise exterior, anticlockwise hole.
        let exterior: [[Double]] = [[0, 0], [0, 10], [10, 10], [10, 0], [0, 0]]
        let hole: [[Double]] = [[2, 2], [4, 2], [4, 4], [2, 4], [2, 2]]
        let island: [[Double]] = [[20, 20], [20, 25], [25, 25], [25, 20], [20, 20]]
        XCTAssertLessThan(WKBWriter.signedArea(exterior), 0)
        XCTAssertGreaterThan(WKBWriter.signedArea(hole), 0)

        let single = WKBWriter.encode(.polygon(rings: [exterior, hole]), hasZ: false, hasM: false)
        XCTAssertEqual(single.kind, .polygon)
        let s = try wkt(single)
        XCTAssertTrue(s.valid, s.text)
        XCTAssertEqual(s.text, "POLYGON ((0 0, 0 10, 10 10, 10 0, 0 0), (2 2, 4 2, 4 4, 2 4, 2 2))")

        let multi = WKBWriter.encode(.polygon(rings: [hole, island, exterior]), hasZ: false, hasM: false)
        XCTAssertEqual(multi.kind, .multiPolygon, "two exteriors, hole assigned by containment regardless of order")
        let m = try wkt(multi)
        XCTAssertTrue(m.valid, m.text)
        XCTAssertEqual(m.type, "MULTIPOLYGON")
        XCTAssertTrue(m.text.contains("(2 2, 4 2, 4 4, 2 4, 2 2)"), "the hole stays inside the first exterior")

        let orphan = WKBWriter.encode(.polygon(rings: [hole]), hasZ: false, hasM: false)
        XCTAssertEqual(orphan.kind, .polygon, "a lone anticlockwise ring is promoted, not dropped")
        XCTAssertTrue(try wkt(orphan).valid)

        let unclosed = WKBWriter.encode(.polygon(rings: [[[0, 0], [0, 1], [1, 1]]]), hasZ: false, hasM: false)
        XCTAssertEqual(try wkt(unclosed).text, "POLYGON ((0 0, 0 1, 1 1, 0 0))", "rings are closed if the server did not")
    }

    func testZAndMTypeCodes() throws {
        let z = WKBWriter.encode(.point([1, 2, 3]), hasZ: true, hasM: false)
        XCTAssertEqual(z.typeName, "Point Z")
        XCTAssertEqual(try wkt(z).text, "POINT Z (1 2 3)")
        let zm = WKBWriter.encode(.polyline(paths: [[[0, 0, 1, 9], [1, 1, 2, 8]]]), hasZ: true, hasM: true)
        XCTAssertEqual(zm.typeName, "LineString ZM")
        XCTAssertEqual(try wkt(zm).text, "LINESTRING ZM (0 0 1 9, 1 1 2 8)")
        let m = WKBWriter.encode(.point([1, 2, 7]), hasZ: false, hasM: true)
        XCTAssertEqual(m.typeName, "Point M")
        XCTAssertEqual(try wkt(m).text, "POINT M (1 2 7)")
    }

    // MARK: - PBF against JSON

    private func pages(_ stem: String, jsonName: String? = nil) throws -> (pbf: FeaturePage, json: FeaturePage) {
        let pbf = try PBFDecoder.decode(try Fixtures.data("\(stem).pbf"))
        let json = FeaturePage(json: try ArcGISJSON.decode(FeatureSet.self, from: try Fixtures.data(jsonName ?? "\(stem).json")))
        return (pbf, json)
    }

    private func assertSameFeatures(_ pbf: FeaturePage, _ json: FeaturePage, tolerance: Double, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pbf.fields.map(\.name), json.fields.map(\.name), "field names", file: file, line: line)
        XCTAssertEqual(pbf.fields.map(\.type), json.fields.map(\.type), "field types", file: file, line: line)
        XCTAssertEqual(pbf.features.count, json.features.count, "feature count", file: file, line: line)
        XCTAssertEqual(pbf.exceededTransferLimit, json.exceededTransferLimit, file: file, line: line)
        XCTAssertEqual(pbf.geometryType, json.geometryType, file: file, line: line)
        for (index, (a, b)) in zip(pbf.features, json.features).enumerated() {
            for (field, (x, y)) in zip(pbf.fields, zip(a.attributes, b.attributes)) {
                switch (x, y) {
                case (.double(let p), .double(let q)): XCTAssertEqual(p, q, accuracy: 1e-6, "\(field.name) in feature \(index)", file: file, line: line)
                case (.double(let p), .int(let q)), (.int(let q), .double(let p)): XCTAssertEqual(p, Double(q), accuracy: 1e-6, "\(field.name) in feature \(index)", file: file, line: line)
                default: XCTAssertEqual(x, y, "\(field.name) in feature \(index)", file: file, line: line)
                }
            }
            assertSameGeometry(a.geometry, b.geometry, tolerance: tolerance, index: index, file: file, line: line)
        }
    }

    private func assertSameGeometry(_ a: EsriGeometry?, _ b: EsriGeometry?, tolerance: Double, index: Int, file: StaticString, line: UInt) {
        func flat(_ g: EsriGeometry?) -> [[[Double]]] {
            switch g {
            case .point(let c)?: return [[c]]
            case .multipoint(let p)?: return [p]
            case .polyline(let paths)?: return paths
            case .polygon(let rings)?: return rings
            case .envelope(let xmin, let ymin, let xmax, let ymax)?: return [[[xmin, ymin], [xmax, ymax]]]
            case nil: return []
            }
        }
        let p = flat(a), q = flat(b)
        XCTAssertEqual(p.count, q.count, "part count in feature \(index)", file: file, line: line)
        for (partIndex, (u, v)) in zip(p, q).enumerated() {
            XCTAssertEqual(u.count, v.count, "vertex count in feature \(index) part \(partIndex)", file: file, line: line)
            for (i, (c, d)) in zip(u, v).enumerated() {
                XCTAssertEqual(c[0], d[0], accuracy: tolerance, "x of vertex \(i) in feature \(index) part \(partIndex)", file: file, line: line)
                XCTAssertEqual(c[1], d[1], accuracy: tolerance, "y of vertex \(i) in feature \(index) part \(partIndex)", file: file, line: line)
            }
        }
    }

    func testCensusPolygonsAgree() throws {
        let (pbf, json) = try pages("s6-census-l3-features")
        XCTAssertEqual(pbf.features.count, 3)
        XCTAssertEqual(pbf.wkid, 4326)
        XCTAssertFalse(pbf.hasZ)
        assertSameFeatures(pbf, json, tolerance: 1e-7)
        for feature in pbf.features {
            let encoded = WKBWriter.encode(try XCTUnwrap(feature.geometry), hasZ: false, hasM: false)
            let result = try wkt(encoded)
            XCTAssertTrue(result.valid, "feature \(feature.attributes[0]) → \(result.type)")
        }
        // Hawaii: several exteriors → MultiPolygon.
        XCTAssertEqual(WKBWriter.encode(try XCTUnwrap(pbf.features[0].geometry), hasZ: false, hasM: false).kind, .multiPolygon)
    }

    func testWildfirePointsLinesPolygonsAgree() throws {
        let points = try pages("s6-wildfire-l0-page")
        assertSameFeatures(points.pbf, points.json, tolerance: 1e-7)
        XCTAssertEqual(points.pbf.geometryType, "esriGeometryPoint")
        let lines = try pages("s6-wildfire-l1-page")
        assertSameFeatures(lines.pbf, lines.json, tolerance: 1e-7)
        XCTAssertEqual(lines.pbf.geometryType, "esriGeometryPolyline")
        let polygons = try pages("s6-wildfire-l2-page")
        assertSameFeatures(polygons.pbf, polygons.json, tolerance: 1e-7)
        XCTAssertEqual(polygons.pbf.geometryType, "esriGeometryPolygon")
        for page in [points.pbf, lines.pbf, polygons.pbf] {
            for feature in page.features {
                guard let geometry = feature.geometry else { continue }
                let result = try wkt(WKBWriter.encode(geometry, hasZ: page.hasZ, hasM: page.hasM))
                XCTAssertTrue(result.valid, result.text)
            }
        }
    }

    func testPBFDatesAndNullsMatchJSON() throws {
        let (pbf, json) = try pages("s6-wildfire-l0-page")
        let created = try XCTUnwrap(pbf.fields.firstIndex { $0.name == "created_date" })
        XCTAssertEqual(pbf.features[0].attributes[created], json.features[0].attributes[created])
        guard case .int = pbf.features[0].attributes[created] else { return XCTFail("dates are epoch millisecond ints") }
        let rotation = try XCTUnwrap(pbf.fields.firstIndex { $0.name == "rotation" })
        XCTAssertEqual(pbf.features[0].attributes[rotation], .null)
    }

    func testNonFeatureResultsAreRejected() {
        XCTAssertThrowsError(try PBFDecoder.decode(Data([0xFF, 0x00, 0x12]))) { error in
            guard case PBFError.malformed? = error as? PBFError else { return XCTFail("expected .malformed, got \(error)") }
        }
        XCTAssertThrowsError(try PBFDecoder.decode(Data())) { error in
            XCTAssertEqual(error as? PBFError, .notAFeatureResult("empty"))
        }
    }

    func testAttributeValueFromJSON() {
        XCTAssertEqual(AttributeValue(.number(3)), .int(3))
        XCTAssertEqual(AttributeValue(.number(3.5)), .double(3.5))
        XCTAssertEqual(AttributeValue(.number(1_782_132_691_000)), .int(1_782_132_691_000))
        XCTAssertEqual(AttributeValue(.string("x")), .string("x"))
        XCTAssertEqual(AttributeValue(nil), .null)
        XCTAssertEqual(AttributeValue(.null), .null)
        XCTAssertEqual(AttributeValue(.bool(true)), .bool(true))
        XCTAssertEqual(AttributeValue.double(2).int64, 2)
        XCTAssertNil(AttributeValue.double(2.5).int64)
    }
}
