import XCTest
import Foundation
import RumenKit

final class QueryTests: XCTestCase {

    // MARK: - Geometry

    func testGeometryParsing() throws {
        func geometry(_ json: String) -> EsriGeometry? {
            EsriGeometry(json: try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)))
        }
        XCTAssertEqual(geometry(#"{"x":-122.5,"y":37.25}"#), .point([-122.5, 37.25]))
        XCTAssertEqual(geometry(#"{"x":1,"y":2,"z":3,"m":4}"#), .point([1, 2, 3, 4]))
        XCTAssertNil(geometry(#"{"x":"NaN","y":"NaN"}"#), "empty point")
        XCTAssertEqual(geometry(#"{"points":[[1,2],[3,4]]}"#), .multipoint([[1, 2], [3, 4]]))
        XCTAssertEqual(geometry(#"{"paths":[[[0,0],[1,1]],[[2,2],[3,3],[4,4]]]}"#),
                       .polyline(paths: [[[0, 0], [1, 1]], [[2, 2], [3, 3], [4, 4]]]))
        XCTAssertEqual(geometry(#"{"rings":[[[0,0],[0,1],[1,1],[0,0]]]}"#), .polygon(rings: [[[0, 0], [0, 1], [1, 1], [0, 0]]]))
        XCTAssertNil(geometry(#"{"rings":[]}"#), "empty polygon")
        XCTAssertEqual(geometry(#"{"xmin":0,"ymin":1,"xmax":2,"ymax":3}"#), .envelope(xmin: 0, ymin: 1, xmax: 2, ymax: 3))
        XCTAssertNil(geometry("null"))
        XCTAssertNil(geometry(#"{"unknown":1}"#))
    }

    func testGeometrySummaries() {
        XCTAssertEqual(EsriGeometry.point([-122.26679240296625, 37.868449696882806]).summary, "POINT (-122.266792 37.86845)")
        XCTAssertEqual(EsriGeometry.point([1, 2, 3]).summary, "POINT (1 2)")
        XCTAssertEqual(EsriGeometry.multipoint([[1, 2]]).summary, "MULTIPOINT, 1 point")
        XCTAssertEqual(EsriGeometry.polyline(paths: [[[0, 0], [1, 1]], [[2, 2], [3, 3], [4, 4]]]).summary, "POLYLINE, 2 paths, 5 vertices")
        XCTAssertEqual(EsriGeometry.polygon(rings: [[[0, 0], [0, 1], [1, 1], [0, 0]]]).summary, "POLYGON, 1 ring, 4 vertices")
        XCTAssertEqual(EsriGeometry.envelope(xmin: 0, ymin: 1, xmax: 2.5, ymax: 3).summary, "ENVELOPE (0 1, 2.5 3)")
        XCTAssertTrue(EsriGeometry.point([1, 2, 3]).hasZOrM)
        XCTAssertFalse(EsriGeometry.polygon(rings: [[[0, 0]]]).hasZOrM)
    }

    // MARK: - Feature sets from fixtures

    func testCensusFeaturePage() throws {
        let set = try ArcGISJSON.decode(FeatureSet.self, from: Fixtures.data("s6-census-l3-features.json"))
        XCTAssertEqual(set.geometryType, "esriGeometryPolygon")
        XCTAssertEqual(set.spatialReference?.effectiveWkid, 4326)
        XCTAssertEqual(set.fields.map(\.name), ["STATE_NAME", "POP2000", "STATE_ABBR"])
        XCTAssertEqual(set.features.count, 3)
        XCTAssertEqual(set.features[0].attributes["STATE_NAME"], .string("Hawaii"))
        XCTAssertEqual(set.features[0].attributes["POP2000"], .number(1_211_537))
        guard case .polygon(let rings)? = set.features[0].geometry else { return XCTFail("expected a polygon") }
        XCTAssertGreaterThan(rings.count, 1, "Hawaii is several islands")
        XCTAssertTrue(set.exceededTransferLimit, "3 of 51")
        XCTAssertTrue(set.hasGeometry)

        let grid = QueryGrid.features(set)
        XCTAssertEqual(grid.columns.map(\.name), ["STATE_NAME", "POP2000", "STATE_ABBR", "geometry"])
        XCTAssertEqual(grid.columns.map(\.typeLabel), ["String 25", "Integer", "String 2", "Geometry"])
        XCTAssertEqual(grid.columns.map(\.isNumeric), [false, true, false, false])
        XCTAssertEqual(grid.rows[0][0], "Hawaii")
        XCTAssertEqual(grid.rows[0][1], "1211537")
        XCTAssertTrue(grid.rows[0][3].hasPrefix("POLYGON, "), grid.rows[0][3])
    }

    func testPageWithoutGeometryAndTransferFlag() throws {
        let set = try ArcGISJSON.decode(FeatureSet.self, from: Fixtures.data("s6-census-l3-features-page2.json"))
        XCTAssertFalse(set.hasGeometry)
        XCTAssertTrue(set.exceededTransferLimit)
        let grid = QueryGrid.features(set)
        XCTAssertEqual(grid.columns.map(\.name), ["STATE_NAME", "OBJECTID"])
        XCTAssertEqual(grid.rows.map { $0[1] }, ["4", "5", "6"])
    }

    func testDatesAndNullsRender() throws {
        let set = try ArcGISJSON.decode(FeatureSet.self, from: Fixtures.data("s6-wildfire-l0-features.json"))
        let grid = QueryGrid.features(set)
        let columns = grid.columns.map(\.name)
        let created = columns.firstIndex(of: "created_date")!
        let rotation = columns.firstIndex(of: "rotation")!
        let eventdate = columns.firstIndex(of: "eventdate")!
        XCTAssertEqual(grid.rows[0][created], "2026-06-22T12:51:31Z")
        XCTAssertEqual(grid.rows[0][rotation], "NULL")
        XCTAssertEqual(grid.rows[0][eventdate], "NULL")
        XCTAssertEqual(grid.rows[0].last, "POINT (-122.266792 37.86845)")
        XCTAssertEqual(QueryGrid.isoDate(millis: 1_782_132_691_250), "2026-06-22T12:51:31.250Z")
        XCTAssertEqual(QueryGrid.cell(.number(2.5), type: .double), "2.5")
        XCTAssertEqual(QueryGrid.cell(.number(1e20), type: .double), "100000000000000000000")
        XCTAssertEqual(QueryGrid.cell(.bool(true), type: .string), "true")
        XCTAssertEqual(QueryGrid.cell(nil, type: .string), "NULL")
    }

    func testDistinctValues() throws {
        let set = try ArcGISJSON.decode(FeatureSet.self, from: Fixtures.data("s6-census-l3-distinct.json"))
        let grid = QueryGrid.features(set)
        XCTAssertEqual(grid.columns.map(\.name), ["SUB_REGION"])
        XCTAssertEqual(grid.rowCount, 9)
        XCTAssertTrue(grid.rows.contains(["Pacific"]))
    }

    func testStatisticsGrid() throws {
        let set = try ArcGISJSON.decode(FeatureSet.self, from: Fixtures.data("s6-census-l3-stats.json"))
        let definitions = [StatisticDefinition(.min, field: "POP2000"), StatisticDefinition(.max, field: "POP2000"),
                           StatisticDefinition(.avg, field: "POP2000"), StatisticDefinition(.count, field: "POP2000")]
        let grid = QueryGrid.statistics(set, definitions: definitions, fieldTypes: ["POP2000": .integer])
        XCTAssertEqual(grid.columns.map(\.name), ["field", "count", "min", "max", "avg"])
        XCTAssertEqual(grid.rows, [["POP2000", "51", "493782", "33871648", "5518076.588235294"]], "the mean loses the 17th digit to Double")
    }

    func testOverviewStatisticDefinitions() {
        let fields = [
            FieldRecord(id: 1, layerID: 1, position: 0, name: "OBJECTID", esriType: .oid, duckType: "BIGINT"),
            FieldRecord(id: 2, layerID: 1, position: 1, name: "POP", esriType: .integer, duckType: "INTEGER"),
            FieldRecord(id: 3, layerID: 1, position: 2, name: "WHEN", esriType: .date, duckType: "TIMESTAMP"),
            FieldRecord(id: 4, layerID: 1, position: 3, name: "NAME", esriType: .string, duckType: "VARCHAR"),
        ]
        let defs = StatisticDefinition.overview(for: fields)
        XCTAssertEqual(defs.map { "\($0.statisticType.rawValue)_\($0.onStatisticField)" },
                       ["min_POP", "max_POP", "avg_POP", "count_POP", "min_WHEN", "max_WHEN", "count_WHEN"])
        XCTAssertEqual(defs[0].outStatisticFieldName, "min_POP")
    }

    func testExtentAndErrorFixtures() throws {
        let extent = try ArcGISJSON.decode(ExtentResponse.self, from: Fixtures.data("s6-census-l3-extent.json")).extent
        XCTAssertEqual(extent.xmin ?? 0, -178.2176, accuracy: 0.001)
        XCTAssertEqual(extent.spatialReference?.wkid, 4326)
        let envelope = try XCTUnwrap(ArcGISJSON.errorEnvelope(in: try Fixtures.data("s6-census-l3-bad-where.json")))
        XCTAssertEqual(envelope.error.code, 400)
        XCTAssertEqual(envelope.error.message, "Unable to complete operation.")
    }

    // MARK: - Options → parameters

    func testQueryOptionsParameters() {
        var o = QueryOptions()
        XCTAssertEqual(o.params, ["where": "1=1", "outFields": "*", "returnGeometry": "true"])
        o.whereClause = "  STATE_ABBR = 'CA'  "
        o.outFields = ["A", "B"]
        o.outWkid = 4326
        o.orderBy = ("OBJECTID", false)
        o.offset = 20
        o.count = 10
        XCTAssertEqual(o.params, ["where": "STATE_ABBR = 'CA'", "outFields": "A,B", "returnGeometry": "true", "outSR": "4326",
                                  "orderByFields": "OBJECTID DESC", "resultOffset": "20", "resultRecordCount": "10"])
        var d = QueryOptions(outFields: ["SUB_REGION"], distinct: true)
        d.returnGeometry = true
        XCTAssertEqual(d.params["returnDistinctValues"], "true")
        XCTAssertEqual(d.params["returnGeometry"], "false", "distinct never asks for geometry")
        let s = QueryOptions(statistics: [StatisticDefinition(.min, field: "POP2000")])
        XCTAssertEqual(s.params["returnGeometry"], "false")
        XCTAssertEqual(s.params["outStatistics"], #"[{"onStatisticField":"POP2000","outStatisticFieldName":"min_POP2000","statisticType":"min"}]"#)
        XCTAssertEqual(QueryOptions(whereClause: "   ").params["where"], "1=1")
        XCTAssertEqual(QueryOptions(outFields: []).params["outFields"], "*")
    }

    // MARK: - Client calls through the stub

    func testFeaturesAndExtentCalls() async throws {
        let transport = StubTransport { request, _ in
            let body = request.encodedParams
            if body.contains("returnExtentOnly=true") { return try .fixture("s6-census-l3-extent.json") }
            if body.contains("returnDistinctValues=true") { return try .fixture("s6-census-l3-distinct.json") }
            if body.contains("where=NOPE") { return try .fixture("s6-census-l3-bad-where.json") }
            return try .fixture("s6-census-l3-features.json")
        }
        let client = ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 1))
        let root = URL(string: "https://sampleserver6.arcgisonline.com/arcgis/rest/services")!
        let server = ServerConnection(rootURL: root)
        let layer = root.appendingPathComponent("Census/MapServer/3")

        let page = try await client.features(server, layerURL: layer,
                                             options: QueryOptions(outFields: ["STATE_NAME"], outWkid: 4326, count: 3)).value
        XCTAssertEqual(page.features.count, 3)
        XCTAssertEqual(transport.last?.httpMethod, "POST")
        XCTAssertEqual(transport.last?.encodedParams, "f=json&outFields=STATE_NAME&outSR=4326&resultRecordCount=3&returnGeometry=true&where=1%3D1")

        let extent = try await client.extent(server, layerURL: layer, outWkid: 4326)
        XCTAssertEqual(extent.ymax ?? 0, 71.406, accuracy: 0.001)

        let distinct = try await client.features(server, layerURL: layer, options: QueryOptions(outFields: ["SUB_REGION"], distinct: true)).value
        XCTAssertEqual(distinct.features.count, 9)

        await XCTAssertThrowsErrorAsync(try await client.features(server, layerURL: layer, options: QueryOptions(whereClause: "NOPE == 1"))) { error in
            guard case ArcGISClientError.server(let code, let message, _, _)? = error as? ArcGISClientError else {
                return XCTFail("expected a server error, got \(error)")
            }
            XCTAssertEqual(code, 400)
            XCTAssertEqual(message, "Unable to complete operation.")
        }
    }

    // MARK: - History

    func testQueryHistoryRoundTrip() async throws {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await db.recordQuery(layerID: 7, whereClause: "1=1", outFields: "*", count: 51, durationMillis: 120, at: t1)
        XCTAssertEqual(first.id, 1)
        try await db.recordQuery(layerID: 7, whereClause: "POP2000 > 1000000", outFields: "STATE_NAME", count: nil,
                                 durationMillis: nil, at: t1.addingTimeInterval(60))
        try await db.recordQuery(layerID: 8, whereClause: "other layer", outFields: nil, count: 1, durationMillis: 1, at: t1)
        let history = try await db.queryHistory(layerID: 7)
        XCTAssertEqual(history.map(\.whereClause), ["POP2000 > 1000000", "1=1"], "newest first")
        XCTAssertEqual(history[1].count, 51)
        XCTAssertEqual(history[1].durationMillis, 120)
        XCTAssertEqual(history[1].ranAt, t1)
        XCTAssertNil(history[0].count)
    }
}
