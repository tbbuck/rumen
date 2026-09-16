import XCTest
import Foundation
import ArcGISKit
import SQLiteKit

/// Opt-in network test against a real public server. Skipped unless `ARCGIS_LIVE=1` is in the
/// environment (see `claude-scripts/live_test.sh`). Proves the real URLSession path: headers,
/// encoding, and the crawl end to end.
final class LiveCrawlTests: XCTestCase {

    func testOpenCensusLayerOnSampleServer6() async throws {
        guard ProcessInfo.processInfo.environment["ARCGIS_LIVE"] == "1" else {
            throw XCTSkip("set ARCGIS_LIVE=1 to run against the network")
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        let client = ArcGISClient()
        let crawler = Crawler(client: client, database: db)

        let opened = try await crawler.open("https://sampleserver6.arcgisonline.com/arcgis/rest/services/Census/MapServer/3")
        XCTAssertTrue(opened.isNewServer)
        XCTAssertEqual(opened.server.arcgisVersion, 10.91)
        let services = try await db.services(serverID: opened.server.id)
        XCTAssertGreaterThan(services.count, 50)
        XCTAssertTrue(services.contains { $0.folderPath == "Utilities" })

        let layer = try XCTUnwrap(opened.layer)
        XCTAssertEqual(layer.name, "states")
        XCTAssertTrue(layer.isCrawled)
        XCTAssertEqual(layer.objectIdField, "OBJECTID")
        XCTAssertTrue(layer.queryFormats.contains("PBF"))
        let fields = try await db.fields(layerID: layer.id)
        XCTAssertGreaterThan(fields.count, 10)

        let count = try await client.count(opened.server.connection(), layerURL: opened.location.layerURL!)
        XCTAssertGreaterThan(count, 0)
    }
}
