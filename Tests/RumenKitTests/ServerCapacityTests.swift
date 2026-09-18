import XCTest
import Foundation
import RumenKit

/// What a run learns and keeps: a width against the server it was talking to, a page size
/// against the layer it was reading.
final class ServerCapacityTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!
    private var slow: Int64!
    private var fast: Int64!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        db = try AppDatabase(path: scratch.appendingPathComponent("app.sqlite").path)
        try await db.migrate()
        slow = try await db.addServer(rootURL: URL(string: "https://slow.example/arcgis/rest/services")!,
                                      friendlyName: "Slow").id
        fast = try await db.addServer(rootURL: URL(string: "https://fast.example/arcgis/rest/services")!,
                                      friendlyName: "Fast").id
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Two layers of the same service, to check they are told apart.
    private func layers(serverID: Int64) async throws -> (points: Int64, polygons: Int64) {
        let root = try await db.server(id: serverID).rootURL
        let service = try await db.upsertServices(serverID: serverID, rootURL: root, folderPath: "", entries: [
            .init(name: "Planning", type: "FeatureServer"),
        ])[0]
        let made = try await db.upsertLayers(serviceID: service.id, layers: [
            .init(id: 0, name: "Points", type: "Feature Layer"),
            .init(id: 1, name: "Polygons", type: "Feature Layer"),
        ], tables: [])
        return (made[0].id, made[1].id)
    }

    // MARK: - Concurrency, which belongs to the server

    func testAnUnknownServerHasNothingRemembered() async throws {
        let remembered = try await db.serverConcurrency(serverID: 9_999)
        XCTAssertNil(remembered)
    }

    func testConcurrencyRoundTripsAndIsReplaced() async throws {
        try await db.recordServerConcurrency(2, serverID: slow)
        var remembered = try await db.serverConcurrency(serverID: slow)
        XCTAssertEqual(remembered, 2)

        try await db.recordServerConcurrency(4, serverID: slow)
        remembered = try await db.serverConcurrency(serverID: slow)
        XCTAssertEqual(remembered, 4)
    }

    /// Servers are independent: one weak box must not drag down a healthy one.
    func testServersAreKeptApart() async throws {
        try await db.recordServerConcurrency(1, serverID: slow)
        try await db.recordServerConcurrency(8, serverID: fast)
        let slowWidth = try await db.serverConcurrency(serverID: slow)
        let fastWidth = try await db.serverConcurrency(serverID: fast)
        XCTAssertEqual(slowWidth, 1)
        XCTAssertEqual(fastWidth, 8)
    }

    /// The reason this is keyed on the server and not the host. ArcGIS Online puts thousands of
    /// unrelated organisations behind one name: what one tenant's layer coped with says nothing
    /// whatever about another's, and it used to decide how another's download opened.
    func testTwoTenantsOnOneHostDoNotShareWhatTheyLearned() async throws {
        let root = "https://services-eu1.arcgis.com"
        let a = try await db.addServer(rootURL: URL(string: "\(root)/AbC123/arcgis/rest/services")!, friendlyName: "Org A").id
        let b = try await db.addServer(rootURL: URL(string: "\(root)/XyZ789/arcgis/rest/services")!, friendlyName: "Org B").id
        XCTAssertNotEqual(a, b)

        try await db.recordServerConcurrency(1, serverID: a)
        let bBeforeItRan = try await db.serverConcurrency(serverID: b)
        XCTAssertNil(bBeforeItRan, "one tenant's bad afternoon is not the other's problem")

        try await db.recordServerConcurrency(4, serverID: b)
        let aWidth = try await db.serverConcurrency(serverID: a)
        let bWidth = try await db.serverConcurrency(serverID: b)
        XCTAssertEqual(aWidth, 1)
        XCTAssertEqual(bWidth, 4)
    }

    /// Forgetting a server takes what it learned with it, rather than leaving a row behind to be
    /// inherited by whatever is registered next.
    func testForgettingAServerDropsWhatItLearned() async throws {
        try await db.recordServerConcurrency(2, serverID: slow)
        try await db.forgetServer(id: slow)
        let afterForgetting = try await db.serverConcurrency(serverID: slow)
        XCTAssertNil(afterForgetting)
    }

    // MARK: - Page size, which belongs to the layer

    func testAnUnreadLayerHasNoPageSize() async throws {
        let (points, _) = try await layers(serverID: slow)
        let remembered = try await db.layerPageSize(layerID: points)
        XCTAssertNil(remembered)
    }

    /// The point of moving it off the server: a points layer and a polygon layer on one machine
    /// give wildly different amounts per request, and one number for both meant every download
    /// opened at a size learned somewhere it did not apply.
    func testTwoLayersOfOneServiceKeepTheirOwnPageSize() async throws {
        let (points, polygons) = try await layers(serverID: slow)
        try await db.recordLayerPageSize(5_000, layerID: points)
        try await db.recordLayerPageSize(400, layerID: polygons)
        let pointsPage = try await db.layerPageSize(layerID: points)
        let polygonsPage = try await db.layerPageSize(layerID: polygons)
        XCTAssertEqual(pointsPage, 5_000)
        XCTAssertEqual(polygonsPage, 400)
    }

    /// A re-crawl rewrites a layer's metadata from the server. What the app worked out for
    /// itself is not the server's to overwrite.
    func testARecrawlLeavesTheLearnedPageSizeAlone() async throws {
        let (points, _) = try await layers(serverID: slow)
        try await db.recordLayerPageSize(2_000, layerID: points)

        let service = try await db.services(serverID: slow)[0]
        _ = try await db.upsertLayers(serviceID: service.id, layers: [
            .init(id: 0, name: "Points, renamed", type: "Feature Layer"),
            .init(id: 1, name: "Polygons", type: "Feature Layer"),
        ], tables: [])

        let remembered = try await db.layerPageSize(layerID: points)
        XCTAssertEqual(remembered, 2_000)
        let renamed = try await db.layer(id: points)
        XCTAssertEqual(renamed.name, "Points, renamed", "the crawl still wrote what is the server's to say")
    }
}
