import XCTest
import Foundation
import RumenKit
import SQLiteKit

final class FieldSearchTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!
    private var s6: Int64 = 0
    private var hosted: Int64 = 0

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        // Two servers, three crawled layers, one uncrawled service.
        let a = try await db.addServer(rootURL: URL(string: "https://sampleserver6.arcgisonline.com/arcgis/rest/services")!, friendlyName: "Sample 6")
        s6 = a.id
        let census = try await db.upsertServices(serverID: a.id, rootURL: a.rootURL, folderPath: "",
                                                 entries: [.init(name: "Census", type: "MapServer"), .init(name: "Wildfire", type: "FeatureServer")])
        let info = try ArcGISJSON.decode(ServiceInfo.self, from: Fixtures.data("s6-census-mapserver.json"))
        try await db.updateService(id: census[0].id, info: info, raw: Data())
        let layers = try await db.upsertLayers(serviceID: census[0].id, layers: info.layers, tables: [])
        let raw3 = try Fixtures.data("s6-census-layer3.json")
        try await db.updateLayer(id: layers[3].id, info: try ArcGISJSON.decode(LayerInfo.self, from: raw3), raw: raw3)
        try await db.setExtractability(layerID: layers[3].id, extractable: true, reason: nil, transport: "pbf", siblingLayerID: nil)
        let b = try await db.addServer(rootURL: URL(string: "https://services3.arcgis.com/GVgbJbqm8hXASVYi/arcgis/rest/services")!, friendlyName: "Hosted")
        hosted = b.id
        let trail = try await db.upsertServices(serverID: b.id, rootURL: b.rootURL, folderPath: "", entries: [.init(name: "Trailheads", type: "FeatureServer")])[0]
        let tinfo = try ArcGISJSON.decode(ServiceInfo.self, from: Fixtures.data("hosted-trailheads-featureserver.json"))
        try await db.updateService(id: trail.id, info: tinfo, raw: Data())
        let tl = try await db.upsertLayers(serviceID: trail.id, layers: [.init(id: 0, name: "Trailheads", type: "Feature Layer")], tables: [])[0]
        let rawT = try Fixtures.data("hosted-trailheads-layer0.json")
        try await db.updateLayer(id: tl.id, info: try ArcGISJSON.decode(LayerInfo.self, from: rawT), raw: rawT)
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A regex search cannot push its filter into SQLite, so it has to look at every candidate
    /// itself. It used to materialise the whole set first — on a server with thousands of
    /// services that is hundreds of thousands of rows in memory before one is tested — and now
    /// reads in batches. The match here sits past the first batch, so a scan that stopped there
    /// would miss it entirely.
    func testARegexSearchReadsBeyondTheFirstBatch() async throws {
        let found = try await anyCrawledLayerID()
        let layerID = try XCTUnwrap(found)
        let total = AppDatabase.scanBatch + 250
        try await db.query("BEGIN;")
        for index in 0..<total {
            // Only the very last ones match, and they are ordered last within the layer.
            let name = index >= total - 3 ? "NEEDLE_\(index)" : "filler_\(index)"
            try await db.query("INSERT INTO field (layer_id, position, name, esri_type, duck_type) VALUES (?, ?, ?, ?, ?);",
                               [.int(layerID), .int(Int64(1_000 + index)), .string(name),
                                .string("esriFieldTypeString"), .string("VARCHAR")])
        }
        try await db.query("COMMIT;")

        let hits = try await db.searchFields(FieldSearchOptions(text: "^NEEDLE_", regex: true))
        XCTAssertEqual(hits.count, 3, "all three matches found, though they sit past the first batch")
        XCTAssertTrue(hits.allSatisfy { $0.fieldName.hasPrefix("NEEDLE_") })
    }

    /// The scan stops as soon as it has enough, rather than reading everything and trimming.
    func testARegexSearchStopsAtTheLimit() async throws {
        let found = try await anyCrawledLayerID()
        let layerID = try XCTUnwrap(found)
        try await db.query("BEGIN;")
        for index in 0..<50 {
            try await db.query("INSERT INTO field (layer_id, position, name, esri_type, duck_type) VALUES (?, ?, ?, ?, ?);",
                               [.int(layerID), .int(Int64(2_000 + index)), .string("MANY_\(index)"),
                                .string("esriFieldTypeString"), .string("VARCHAR")])
        }
        try await db.query("COMMIT;")

        let hits = try await db.searchFields(FieldSearchOptions(text: "^MANY_", regex: true, limit: 10))
        XCTAssertEqual(hits.count, 10)
    }

    /// The id of a layer that already has fields, to hang synthetic ones off.
    private func anyCrawledLayerID() async throws -> Int64? {
        try await db.query("SELECT layer_id FROM field LIMIT 1;").rows.first?.first?.int64
    }

    func testPartialCaseInsensitiveAcrossServers() async throws {
        let hits = try await db.searchFields(FieldSearchOptions(text: "name"))
        XCTAssertTrue(hits.contains { $0.fieldName == "STATE_NAME" && $0.serverName == "Sample 6" && $0.layerName == "states" })
        XCTAssertTrue(hits.contains { $0.fieldName == "TRL_NAME" && $0.serverName == "Hosted" })
        XCTAssertTrue(hits.contains { $0.fieldName == "PARK_NAME" })
        XCTAssertEqual(hits.first?.serverName, "Hosted", "ordered by server name")
        let states = try XCTUnwrap(hits.first { $0.fieldName == "STATE_NAME" })
        XCTAssertEqual(states.layerNumber, 3)
        XCTAssertEqual(states.extractable, true)
        XCTAssertEqual(states.serviceType, .mapServer)
        XCTAssertEqual(states.duckType, "VARCHAR")
        XCTAssertFalse(states.matchedAlias)
    }

    func testScopeToOneServer() async throws {
        let hits = try await db.searchFields(FieldSearchOptions(text: "name", serverID: s6))
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.serverID == s6 })
        let none = try await db.searchFields(FieldSearchOptions(text: "TRL_NAME", serverID: s6))
        XCTAssertTrue(none.isEmpty)
    }

    func testExactAndCaseSensitive() async throws {
        let exact = try await db.searchFields(FieldSearchOptions(text: "state_name", partial: false))
        XCTAssertEqual(exact.map(\.fieldName), ["STATE_NAME"], "exact but case-insensitive")
        let sensitive = try await db.searchFields(FieldSearchOptions(text: "state_name", caseSensitive: true, partial: false))
        XCTAssertTrue(sensitive.isEmpty)
        let sensitivePartial = try await db.searchFields(FieldSearchOptions(text: "STATE_", caseSensitive: true))
        XCTAssertEqual(Set(sensitivePartial.map(\.fieldName)), ["STATE_NAME", "STATE_FIPS", "STATE_ABBR"])
        let lowerPartial = try await db.searchFields(FieldSearchOptions(text: "state_", caseSensitive: true))
        XCTAssertTrue(lowerPartial.isEmpty)
    }

    func testLikeWildcardsAreLiteral() async throws {
        let hits = try await db.searchFields(FieldSearchOptions(text: "%"))
        XCTAssertTrue(hits.isEmpty, "a percent sign is a character, not a wildcard")
        let underscore = try await db.searchFields(FieldSearchOptions(text: "_NAME"))
        XCTAssertTrue(underscore.allSatisfy { $0.fieldName.contains("_NAME") })
        XCTAssertFalse(underscore.isEmpty)
    }

    func testAliasMatching() async throws {
        try await db.query("UPDATE field SET alias = 'Unique property reference' WHERE name = 'TRL_ID';")
        let withoutAlias = try await db.searchFields(FieldSearchOptions(text: "property"))
        XCTAssertTrue(withoutAlias.isEmpty)
        let withAlias = try await db.searchFields(FieldSearchOptions(text: "property", includeAlias: true))
        XCTAssertEqual(withAlias.map(\.fieldName), ["TRL_ID"])
        XCTAssertTrue(withAlias[0].matchedAlias)
    }

    func testRegex() async throws {
        let hits = try await db.searchFields(FieldSearchOptions(text: "^POP20(00|07)$", regex: true))
        XCTAssertEqual(Set(hits.map(\.fieldName)), ["POP2000", "POP2007"])
        let sensitive = try await db.searchFields(FieldSearchOptions(text: "^pop", caseSensitive: true, regex: true))
        XCTAssertTrue(sensitive.isEmpty)
        let insensitive = try await db.searchFields(FieldSearchOptions(text: "^pop", regex: true))
        XCTAssertFalse(insensitive.isEmpty)
        await XCTAssertThrowsErrorAsync(try await self.db.searchFields(FieldSearchOptions(text: "(", regex: true))) { error in
            guard case FieldSearchError.badRegex? = error as? FieldSearchError else { return XCTFail("expected badRegex, got \(error)") }
        }
    }

    func testEmptyTextAndLimit() async throws {
        let none = try await db.searchFields(FieldSearchOptions(text: "   "))
        XCTAssertTrue(none.isEmpty)
        let two = try await db.searchFields(FieldSearchOptions(text: "a", limit: 2))
        XCTAssertEqual(two.count, 2)
    }

    func testUncrawledServiceCount() async throws {
        let s6Count = try await db.uncrawledServiceCount(serverID: s6)
        XCTAssertEqual(s6Count, 1, "Wildfire was listed but never crawled")
        let all = try await db.uncrawledServiceCount()
        XCTAssertEqual(all, 1)
        let hostedCount = try await db.uncrawledServiceCount(serverID: hosted)
        XCTAssertEqual(hostedCount, 0)
    }
}
