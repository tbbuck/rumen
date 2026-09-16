import XCTest
import Foundation
import ArcGISKit
import SQLiteKit

final class MetadataStoreTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!
    private let root = URL(string: "https://sampleserver6.arcgisonline.com/arcgis/rest/services")!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Servers

    func testAddServerIsIdempotentAndTouchesVisit() async throws {
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try await db.addServer(rootURL: root, friendlyName: "Sample 6", now: t1)
        XCTAssertEqual(first.id, 1)
        XCTAssertEqual(first.friendlyName, "Sample 6")
        XCTAssertEqual(first.authKind, "none")
        XCTAssertEqual(first.createdAt, t1)
        XCTAssertEqual(first.lastVisitedAt, t1)
        XCTAssertEqual(first.headers, ServerHeaders(origin: "https://sampleserver6.arcgisonline.com",
                                                    referer: "https://sampleserver6.arcgisonline.com/"))

        let t2 = t1.addingTimeInterval(60)
        let again = try await db.addServer(rootURL: root, friendlyName: "ignored", now: t2)
        XCTAssertEqual(again.id, 1)
        XCTAssertEqual(again.friendlyName, "Sample 6", "existing name is kept")
        XCTAssertEqual(again.lastVisitedAt, t2)
        let all = try await db.servers()
        XCTAssertEqual(all.count, 1)
        let byURL = try await db.server(rootURL: root)
        XCTAssertEqual(byURL?.id, 1)
        let missing = try await db.server(rootURL: URL(string: "https://other.example/arcgis/rest/services")!)
        XCTAssertNil(missing)
    }

    func testBlankFriendlyNameFallsBackToHost() async throws {
        let s = try await db.addServer(rootURL: root, friendlyName: "  ")
        XCTAssertEqual(s.friendlyName, "sampleserver6.arcgisonline.com")
    }

    func testRenameOverridesVersionAndForget() async throws {
        let s = try await db.addServer(rootURL: root, friendlyName: "x")
        try await db.renameServer(id: s.id, friendlyName: "Sample Server 6")
        try await db.setHeaderOverrides(serverID: s.id, origin: "https://portal.example", referer: " ")
        try await db.setServerVersion(id: s.id, version: 10.91)
        let updated = try await db.server(id: s.id)
        XCTAssertEqual(updated.friendlyName, "Sample Server 6")
        XCTAssertEqual(updated.originOverride, "https://portal.example")
        XCTAssertNil(updated.refererOverride, "blank override stored as NULL")
        XCTAssertEqual(updated.arcgisVersion, 10.91)
        XCTAssertEqual(updated.headers.origin, "https://portal.example")
        XCTAssertEqual(updated.headers.referer, "https://sampleserver6.arcgisonline.com/")
        try await db.setCookie(serverID: s.id, cookie: "  agsession=abc; x=1 ")
        let withCookie = try await db.server(id: s.id)
        XCTAssertEqual(withCookie.cookie, "agsession=abc; x=1", "trimmed, on the row")
        XCTAssertEqual(withCookie.connection().cookie, "agsession=abc; x=1", "and on every connection")
        try await db.setCookie(serverID: s.id, cookie: "   ")
        let cleared = try await db.server(id: s.id)
        XCTAssertNil(cleared.cookie, "blank clears it")

        try await db.forgetServer(id: s.id)
        let remaining = try await db.servers()
        XCTAssertEqual(remaining, [])
        await XCTAssertThrowsErrorAsync(try await self.db.server(id: s.id)) { error in
            XCTAssertEqual(error as? MetadataStoreError, .notFound("server 1"))
        }
    }

    // MARK: - Services + layers from fixtures

    private func crawlCensus() async throws -> (ServerRecord, ServiceRecord, [LayerRecord]) {
        let server = try await db.addServer(rootURL: root, friendlyName: "S6")
        let dir = try ArcGISJSON.decode(ServiceDirectory.self, from: Fixtures.data("s6-root.json"))
        let services = try await db.upsertServices(serverID: server.id, rootURL: root, folderPath: "", entries: dir.services)
        let census = try XCTUnwrap(services.first { $0.name == "Census" && $0.type == .mapServer })
        let raw = try Fixtures.data("s6-census-mapserver.json")
        let info = try ArcGISJSON.decode(ServiceInfo.self, from: raw)
        try await db.updateService(id: census.id, info: info, raw: raw)
        let layers = try await db.upsertLayers(serviceID: census.id, layers: info.layers, tables: info.tables)
        let stored = try await db.service(id: census.id)
        return (server, stored, layers)
    }

    func testServicesFromDirectoryListing() async throws {
        let (server, census, layers) = try await crawlCensus()
        let all = try await db.services(serverID: server.id)
        let listed = try ArcGISJSON.decode(ServiceDirectory.self, from: Fixtures.data("s6-root.json")).services.count
        XCTAssertEqual(all.count, listed)
        XCTAssertGreaterThan(listed, 50)
        XCTAssertEqual(census.url.absoluteString, root.absoluteString + "/Census/MapServer")
        XCTAssertEqual(census.folderPath, "")
        XCTAssertEqual(census.shortName, "Census")
        XCTAssertTrue(census.isCrawled)
        XCTAssertEqual(census.capabilitySet, ["Map", "Query", "Data"])
        XCTAssertEqual(census.maxRecordCount, 1000)
        XCTAssertEqual(census.isTileCache, false)
        let raw = try await db.serviceRawJSON(id: census.id)
        XCTAssertTrue(raw?.contains("\"mapName\":\"Layers\"") == true)
        let uncrawled = try XCTUnwrap(all.first { $0.name == "Wildfire" && $0.type == .featureServer })
        XCTAssertFalse(uncrawled.isCrawled)
        XCTAssertEqual(layers.map(\.layerID), [0, 1, 2, 3])
        XCTAssertEqual(layers[3].name, "states")
        XCTAssertFalse(layers[3].isCrawled)
        XCTAssertEqual(layers[3].geometryType, "esriGeometryPolygon")
    }

    func testFolderServicesAndPrune() async throws {
        let server = try await db.addServer(rootURL: root, friendlyName: "S6")
        let dir = try ArcGISJSON.decode(ServiceDirectory.self, from: Fixtures.data("s6-folder-utilities.json"))
        let services = try await db.upsertServices(serverID: server.id, rootURL: root, folderPath: "Utilities", entries: dir.services)
        XCTAssertEqual(services.map(\.name), ["Utilities/GeocodingTools", "Utilities/Geometry",
                                              "Utilities/PrintingTools", "Utilities/RasterUtilities"])
        XCTAssertEqual(services[1].url.absoluteString, root.absoluteString + "/Utilities/Geometry/GeometryServer")
        XCTAssertEqual(services[1].shortName, "Geometry")
        XCTAssertEqual(services[1].type, .other("GeometryServer"))

        // Re-listing without two of them prunes those two and keeps the rest (with their ids).
        try await db.pruneServices(serverID: server.id, folderPath: "Utilities", keeping: [services[0].url, services[3].url])
        let remaining = try await db.services(serverID: server.id, folderPath: "Utilities")
        XCTAssertEqual(remaining.map(\.id), [services[0].id, services[3].id])
    }

    func testLayerDefinitionAndFields() async throws {
        let (_, census, layers) = try await crawlCensus()
        let raw = try Fixtures.data("s6-census-layer3.json")
        let info = try ArcGISJSON.decode(LayerInfo.self, from: raw)
        let fetched = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.updateLayer(id: layers[3].id, info: info, raw: raw, fetchedAt: fetched)

        let states = try await db.layer(id: layers[3].id)
        XCTAssertTrue(states.isCrawled)
        XCTAssertEqual(states.fetchedAt, fetched)
        XCTAssertEqual(states.objectIdField, "OBJECTID", "resolved from the OID field")
        XCTAssertEqual(states.wkid, 4269)
        XCTAssertEqual(states.effectiveWkid, 4269)
        XCTAssertEqual(states.maxRecordCount, 1000)
        XCTAssertEqual(states.queryFormats, ["JSON", "GEOJSON", "PBF"])
        XCTAssertEqual(states.supportsPagination, true)
        XCTAssertEqual(states.supportsStatistics, true)
        XCTAssertNil(states.extractable, "not assessed yet")
        XCTAssertTrue(states.extentJSON?.hasPrefix("{\"xmin\":-178.") == true, states.extentJSON ?? "nil")
        XCTAssertTrue(states.extentJSON?.hasSuffix("\"wkid\":4269}") == true)

        let fields = try await db.fields(layerID: states.id)
        XCTAssertEqual(fields.count, info.fields.count)
        XCTAssertEqual(fields.map(\.position), Array(0..<info.fields.count))
        let oid = try XCTUnwrap(fields.first { $0.esriType == .oid })
        XCTAssertEqual(oid.duckType, "BIGINT")
        let byLayerID = try await db.layer(serviceID: census.id, layerID: 3)
        XCTAssertEqual(byLayerID?.id, states.id)
        let rawStored = try await db.layerRawJSON(id: states.id)
        XCTAssertTrue(rawStored?.contains("\"name\":\"states\"") == true)

        // Re-storing replaces fields rather than duplicating them.
        try await db.updateLayer(id: states.id, info: info, raw: raw)
        let fieldsAgain = try await db.fields(layerID: states.id)
        XCTAssertEqual(fieldsAgain.count, info.fields.count)
    }

    func testHostedLayerWithDomainAndGlobalID() async throws {
        let server = try await db.addServer(rootURL: URL(string: "https://services3.arcgis.com/GVgbJbqm8hXASVYi/arcgis/rest/services")!,
                                            friendlyName: "Hosted")
        let svc = try await db.upsertServices(serverID: server.id, rootURL: server.rootURL, folderPath: "",
                                              entries: [.init(name: "Trailheads", type: "FeatureServer")])[0]
        let layer = try await db.upsertLayers(serviceID: svc.id,
                                              layers: [.init(id: 0, name: "Trailheads", type: "Feature Layer",
                                                             geometryType: "esriGeometryPoint")], tables: [])[0]
        let raw = try Fixtures.data("hosted-trailheads-layer0.json")
        try await db.updateLayer(id: layer.id, info: try ArcGISJSON.decode(LayerInfo.self, from: raw), raw: raw)
        let stored = try await db.layer(id: layer.id)
        XCTAssertEqual(stored.objectIdField, "FID")
        XCTAssertEqual(stored.globalIdField, "GlobalID")
        XCTAssertEqual(stored.wkid, 102100)
        XCTAssertEqual(stored.latestWkid, 3857)
        XCTAssertEqual(stored.effectiveWkid, 3857)
        XCTAssertEqual(stored.supportsResultType, true)
        let fields = try await db.fields(layerID: layer.id)
        let global = try XCTUnwrap(fields.first { $0.name == "GlobalID" })
        XCTAssertEqual(global.duckType, "UUID")
        XCTAssertEqual(global.length, 38)
        XCTAssertNil(global.domainJSON)
    }

    func testTablesAndPruneLayers() async throws {
        let (_, census, _) = try await crawlCensus()
        let withTable = try await db.upsertLayers(serviceID: census.id, layers: [],
                                                  tables: [.init(id: 7, name: "Lookup")])
        XCTAssertEqual(withTable[0].isTable, true)
        XCTAssertEqual(withTable[0].type, "Table")
        let before = try await db.layers(serviceID: census.id)
        XCTAssertEqual(before.map(\.layerID), [0, 1, 2, 3, 7])
        try await db.pruneLayers(serviceID: census.id, keeping: [0, 3])
        let after = try await db.layers(serviceID: census.id)
        XCTAssertEqual(after.map(\.layerID), [0, 3])
    }

    func testFeatureCountAndExtractability() async throws {
        let (_, _, layers) = try await crawlCensus()
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        try await db.setFeatureCount(layerID: layers[3].id, count: 51, at: at)
        try await db.setExtractability(layerID: layers[3].id, extractable: true, reason: nil, transport: "pbf",
                                       siblingLayerID: nil)
        let l = try await db.layer(id: layers[3].id)
        XCTAssertEqual(l.featureCount, 51)
        XCTAssertEqual(l.featureCountAt, at)
        XCTAssertEqual(l.extractable, true)
        XCTAssertEqual(l.transport, "pbf")
    }

    func testForgetServerCascades() async throws {
        let (server, _, layers) = try await crawlCensus()
        let raw = try Fixtures.data("s6-census-layer3.json")
        try await db.updateLayer(id: layers[3].id, info: try ArcGISJSON.decode(LayerInfo.self, from: raw), raw: raw)
        try await db.forgetServer(id: server.id)
        for table in ["server", "service", "layer", "field"] {
            let count = try await db.query("SELECT count(*) FROM \(table);").scalarString
            XCTAssertEqual(count, "0", table)
        }
    }
}
