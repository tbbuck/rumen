import XCTest
import Foundation
import RumenKit
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

    /// Stratford-on-Avon's planning register fronts an ArcGIS MapServer at a path with no
    /// `rest/services` in it (decision 19): the probe must find it, not take it for OGC.
    func testOpenProxiedLayerAtStratford() async throws {
        guard ProcessInfo.processInfo.environment["ARCGIS_LIVE"] == "1" else {
            throw XCTSkip("set ARCGIS_LIVE=1 to run against the network")
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        let crawler = Crawler(client: ArcGISClient(), database: db)

        let opened = try await crawler.open("https://apps.stratford.gov.uk/EplanningV2/API/v1/Map/3?f=pjson")
        XCTAssertTrue(opened.isNewServer)
        XCTAssertEqual(opened.server.kind, .service)
        XCTAssertEqual(opened.server.rootURL.absoluteString, "https://apps.stratford.gov.uk/EplanningV2/API/v1/Map")
        XCTAssertEqual(opened.server.arcgisVersion, 10.81)
        let service = try XCTUnwrap(opened.service)
        XCTAssertEqual(service.type, .mapServer)
        XCTAssertEqual(service.name, "Map")
        let layers = try await db.layers(serviceID: service.id)
        XCTAssertEqual(layers.count, 5)
        let layer = try XCTUnwrap(opened.layer)
        XCTAssertEqual(layer.name, "Map text")
        XCTAssertEqual(layer.effectiveWkid, 27700)
        XCTAssertTrue(layer.isCrawled)
        let count = try await crawler.probeCount(layerID: layer.id)
        XCTAssertGreaterThan(count, 100_000)
    }

    /// Cherwell's layers sit behind an ArcGIS Online `usrsvcs` proxy that fronts one named
    /// service and enumerates nothing: the root directory and the folder both answer HTTP 200
    /// with an empty body. The open used to die decoding that empty root; the service is
    /// adopted by name instead.
    func testOpenProxiedServiceWhoseDirectoryIsEmpty() async throws {
        guard ProcessInfo.processInfo.environment["ARCGIS_LIVE"] == "1" else {
            throw XCTSkip("set ARCGIS_LIVE=1 to run against the network")
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        let crawler = Crawler(client: ArcGISClient(), database: db)

        let opened = try await crawler.open("https://utility.arcgis.com/usrsvcs/servers/451c388a101c4a659a0697a6826303c7/rest/services/Public_Map_Services/Cherwell_Public_Neighbourhood_Development_Plans_and_Other_Layers/MapServer/2?f=json")
        XCTAssertTrue(opened.isNewServer)
        XCTAssertEqual(opened.server.rootURL.absoluteString,
                       "https://utility.arcgis.com/usrsvcs/servers/451c388a101c4a659a0697a6826303c7/rest/services")
        let service = try XCTUnwrap(opened.service, "the named service must be adopted when nothing lists it")
        XCTAssertEqual(service.type, .mapServer)
        XCTAssertEqual(service.folderPath, "Public_Map_Services")
        let layers = try await db.layers(serviceID: service.id)
        XCTAssertGreaterThan(layers.count, 1)
        let layer = try XCTUnwrap(opened.layer)
        XCTAssertEqual(layer.layerID, 2)
        XCTAssertTrue(layer.isCrawled)
    }

    /// Cherwell's Web AppBuilder viewer. The app names a web map, the web map names five map
    /// services, and each sits behind its own `usrsvcs` proxy with its own GUID — so nothing
    /// enumerates them and the item is the only table of contents there is.
    func testOpenWebAppBuilderViewerFindsEveryServiceItDraws() async throws {
        guard ProcessInfo.processInfo.environment["ARCGIS_LIVE"] == "1" else {
            throw XCTSkip("set ARCGIS_LIVE=1 to run against the network")
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        let crawler = Crawler(client: ArcGISClient(), database: db)

        let item = try XCTUnwrap(PortalURL.parse("https://cherwell.maps.arcgis.com/apps/webappviewer/index.html?id=c4ffa2d7d99949b185c6d622a0f9d8ab"))
        let services = try await crawler.resolvePortalItem(item)
        XCTAssertEqual(services.count, 5, "the web map draws five map services")
        XCTAssertTrue(services.allSatisfy { $0.url.absoluteString.contains("/usrsvcs/servers/") },
                      "every one is proxied: \(services.map(\.url.absoluteString))")

        let opened = try await crawler.open("https://cherwell.maps.arcgis.com/apps/webappviewer/index.html?id=c4ffa2d7d99949b185c6d622a0f9d8ab")
        XCTAssertNotNil(opened.service, "it lands on the first service the item named")
        // Each proxy GUID is its own root, so all five register as separate servers.
        let servers = try await db.servers()
        XCTAssertEqual(servers.count, 5, "opened: \(servers.map(\.friendlyName))")
    }
}
