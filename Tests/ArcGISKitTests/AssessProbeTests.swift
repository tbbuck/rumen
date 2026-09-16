import XCTest
import Foundation
import ArcGISKit
import DuckDBKit

/// The crawler's assess + probe against a stub server: twin discovery crawls the twin once,
/// the verdict is persisted, a count confirms, a server error overturns.
final class AssessProbeTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!
    private var transport: StubTransport!
    private var crawler: Crawler!
    private let root = "https://sampleserver6.arcgisonline.com/arcgis/rest/services"

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        db = try AppDatabase(path: scratch.appendingPathComponent("explorer.duckdb").path)
        try await db.migrate()
        try await db.loadSpatial()
        transport = StubTransport { request, _ in
            let path = request.url!.path
            let s6 = "/arcgis/rest/services"
            switch path {
            case s6: return try .fixture("s6-root.json")
            case "\(s6)/Wildfire/MapServer":
                // A MapServer twin of the Wildfire FeatureServer: JSON only, no paging.
                return .json(#"{"currentVersion":10.91,"capabilities":"Map,Query","supportedQueryFormats":"JSON","maxRecordCount":1000,"layers":[{"id":0,"name":"Wildfire Response Points","type":"Feature Layer","geometryType":"esriGeometryPoint"}],"tables":[]}"#)
            case "\(s6)/Wildfire/MapServer/layers": return .json("nope", status: 404)
            case "\(s6)/Wildfire/MapServer/0":
                return .json(#"{"id":0,"name":"Wildfire Response Points","type":"Feature Layer","geometryType":"esriGeometryPoint","capabilities":"Map,Query","supportedQueryFormats":"JSON","maxRecordCount":1000,"fields":[{"name":"objectid","type":"esriFieldTypeOID"}]}"#)
            case "\(s6)/Wildfire/FeatureServer": return try .fixture("s6-wildfire-featureserver.json")
            case "\(s6)/Wildfire/FeatureServer/layers": return .json("nope", status: 404)
            case "\(s6)/Wildfire/FeatureServer/0": return try .fixture("s6-wildfire-layer0.json")
            case "\(s6)/Wildfire/FeatureServer/0/query": return try .fixture("s6-wildfire-count.json")
            case "\(s6)/Census/MapServer": return try .fixture("s6-census-mapserver.json")
            case "\(s6)/Census/MapServer/layers": return try .fixture("s6-census-layers.json")
            case "\(s6)/Census/MapServer/3/query":
                return .json(#"{"error":{"code":400,"message":"Unable to complete operation.","details":["Layer 3 is not queryable"]}}"#)
            default:
                if path.hasPrefix("\(s6)/Wildfire/FeatureServer/") {
                    let id = path.split(separator: "/").last!
                    return .json(#"{"id":\#(id),"name":"Other \#(id)","type":"Feature Layer","geometryType":"esriGeometryPoint","fields":[{"name":"OBJECTID","type":"esriFieldTypeOID"}]}"#)
                }
                if path.hasPrefix(s6 + "/"), !path.contains("Server") {
                    return .json(#"{"currentVersion":10.91,"folders":[],"services":[]}"#)
                }
                return .json(#"{"error":{"code":404,"message":"not stubbed: \#(path)"}}"#)
            }
        }
        crawler = Crawler(client: ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 2, baseDelay: 0)), database: db)
    }

    override func tearDownWithError() throws {
        crawler = nil; db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    func testMapServerLayerUsesItsFeatureServerTwinAndProbeConfirms() async throws {
        let opened = try await crawler.open(root + "/Wildfire/MapServer/0")
        let layer = try XCTUnwrap(opened.layer)
        let before = transport.count

        let assessment = try await crawler.assess(layerID: layer.id)
        XCTAssertEqual(assessment.verdict, true)
        XCTAssertTrue(assessment.viaTwin, "PBF + paging on the FeatureServer beats JSON-only on the MapServer")
        XCTAssertEqual(assessment.transport, .pbf)
        XCTAssertEqual(assessment.reason, "PBF through the FeatureServer twin, offset paging at 1,000 records per request.")
        let paths = transport.requests.dropFirst(before).compactMap { $0.url?.path }
        XCTAssertTrue(paths.contains("/arcgis/rest/services/Wildfire/FeatureServer"), "the twin service was crawled")

        let stored = try await db.layer(id: layer.id)
        XCTAssertEqual(stored.extractable, true)
        XCTAssertEqual(stored.transport, "pbf")
        XCTAssertEqual(stored.siblingLayerID, assessment.sourceLayerID)
        XCTAssertNotEqual(stored.siblingLayerID, layer.id)

        // Assessing again does not re-crawl the twin.
        let mid = transport.count
        _ = try await crawler.assess(layerID: layer.id)
        XCTAssertEqual(transport.count, mid)

        let count = try await crawler.probeCount(layerID: layer.id)
        XCTAssertEqual(count, 305)
        XCTAssertEqual(transport.last?.url?.path, "/arcgis/rest/services/Wildfire/FeatureServer/0/query", "probed against the twin")
        let confirmed = try await db.layer(id: layer.id)
        XCTAssertEqual(confirmed.featureCount, 305)
        XCTAssertNotNil(confirmed.featureCountAt)
        let twinStored = try await db.layer(id: assessment.sourceLayerID)
        XCTAssertEqual(twinStored.featureCount, 305, "the twin's count is recorded too")
    }

    func testServerErrorOnProbeOverturnsTheVerdict() async throws {
        let opened = try await crawler.open(root + "/Census/MapServer/3")
        let layer = try XCTUnwrap(opened.layer)
        let assessment = try await crawler.assess(layerID: layer.id)
        XCTAssertEqual(assessment.verdict, true, "rules say yes")
        await XCTAssertThrowsErrorAsync(try await self.crawler.probeCount(layerID: layer.id)) { error in
            guard case ArcGISClientError.server(let code, _, let details, _)? = error as? ArcGISClientError else {
                return XCTFail("expected a server error, got \(error)")
            }
            XCTAssertEqual(code, 400)
            XCTAssertEqual(details, ["Layer 3 is not queryable"])
        }
        let stored = try await db.layer(id: layer.id)
        XCTAssertEqual(stored.extractable, false)
        XCTAssertEqual(stored.extractableReason, "The server refused the count probe: Unable to complete operation.")
        XCTAssertNil(stored.featureCount)
    }
}
