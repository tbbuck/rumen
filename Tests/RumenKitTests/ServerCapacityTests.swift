import XCTest
import Foundation
import RumenKit

/// The learned-capacity table: what a registered server coped with, kept for the next run.
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

    func testAnUnknownServerHasNothingRemembered() async throws {
        let capacity = try await db.capacity(serverID: 9_999)
        XCTAssertNil(capacity)
    }

    func testCapacityRoundTrips() async throws {
        try await db.recordCapacity(serverID: slow, concurrency: 2, pageSize: 400)
        let capacity = try await db.capacity(serverID: slow)
        XCTAssertEqual(capacity?.concurrency, 2)
        XCTAssertEqual(capacity?.pageSize, 400)
    }

    func testRecordingAgainReplacesTheOldValues() async throws {
        try await db.recordCapacity(serverID: slow, concurrency: 2, pageSize: 400)
        try await db.recordCapacity(serverID: slow, concurrency: 4, pageSize: 800)
        let capacity = try await db.capacity(serverID: slow)
        XCTAssertEqual(capacity?.concurrency, 4)
        XCTAssertEqual(capacity?.pageSize, 800)
    }

    /// A run that learned about one of the two must not wipe what another run knew about the
    /// other — a crawl has an opinion on concurrency and none at all on page size.
    func testRecordingOneNumberLeavesTheOtherAlone() async throws {
        try await db.recordCapacity(serverID: slow, concurrency: 2, pageSize: 400)
        try await db.recordCapacity(serverID: slow, concurrency: 3)
        var capacity = try await db.capacity(serverID: slow)
        XCTAssertEqual(capacity?.concurrency, 3)
        XCTAssertEqual(capacity?.pageSize, 400, "the page size survived a concurrency-only update")

        try await db.recordCapacity(serverID: slow, pageSize: 900)
        capacity = try await db.capacity(serverID: slow)
        XCTAssertEqual(capacity?.concurrency, 3)
        XCTAssertEqual(capacity?.pageSize, 900)
    }

    func testRecordingNothingIsANoOp() async throws {
        try await db.recordCapacity(serverID: slow)
        let capacity = try await db.capacity(serverID: slow)
        XCTAssertNil(capacity, "a call with nothing to say should not create a row")
    }

    /// Servers are independent: one weak box must not drag down a healthy one.
    func testServersAreKeptApart() async throws {
        try await db.recordCapacity(serverID: slow, concurrency: 1, pageSize: 100)
        try await db.recordCapacity(serverID: fast, concurrency: 8, pageSize: 2_000)
        let slowCapacity = try await db.capacity(serverID: slow)
        let fastCapacity = try await db.capacity(serverID: fast)
        XCTAssertEqual(slowCapacity?.pageSize, 100)
        XCTAssertEqual(fastCapacity?.pageSize, 2_000)
    }

    /// The reason this is keyed on the server and not the host. ArcGIS Online puts thousands of
    /// unrelated organisations behind one name: what one tenant's layer turned out to cope with
    /// says nothing whatever about another's, and it used to decide how another's download
    /// opened. Two roots on one host are two servers here.
    func testTwoTenantsOnOneHostDoNotShareWhatTheyLearned() async throws {
        let root = "https://services-eu1.arcgis.com"
        let a = try await db.addServer(rootURL: URL(string: "\(root)/AbC123/arcgis/rest/services")!, friendlyName: "Org A").id
        let b = try await db.addServer(rootURL: URL(string: "\(root)/XyZ789/arcgis/rest/services")!, friendlyName: "Org B").id
        XCTAssertNotEqual(a, b)

        try await db.recordCapacity(serverID: a, concurrency: 1, pageSize: 100)
        let bBeforeItRan = try await db.capacity(serverID: b)
        XCTAssertNil(bBeforeItRan, "one tenant's bad afternoon is not the other's problem")

        try await db.recordCapacity(serverID: b, concurrency: 4, pageSize: 2_000)
        let aCapacity = try await db.capacity(serverID: a)
        let bCapacity = try await db.capacity(serverID: b)
        XCTAssertEqual(aCapacity?.pageSize, 100)
        XCTAssertEqual(bCapacity?.pageSize, 2_000)
    }

    /// Forgetting a server takes what it learned with it, rather than leaving a row behind to be
    /// inherited by whatever is registered next.
    func testForgettingAServerDropsWhatItLearned() async throws {
        try await db.recordCapacity(serverID: slow, concurrency: 2, pageSize: 400)
        try await db.forgetServer(id: slow)
        let afterForgetting = try await db.capacity(serverID: slow)
        XCTAssertNil(afterForgetting)
    }
}
