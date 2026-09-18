import XCTest
import Foundation
import RumenKit

/// The learned-capacity table: what a host coped with, kept for the next run.
final class ServerCapacityTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        db = try AppDatabase(path: scratch.appendingPathComponent("app.sqlite").path)
        try await db.migrate()
    }

    override func tearDown() async throws {
        db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    func testAnUnknownHostHasNothingRemembered() async throws {
        let capacity = try await db.capacity(host: "https://nobody.example")
        XCTAssertNil(capacity)
    }

    func testCapacityRoundTrips() async throws {
        try await db.recordCapacity(host: "https://slow.example", concurrency: 2, pageSize: 400)
        let capacity = try await db.capacity(host: "https://slow.example")
        XCTAssertEqual(capacity?.concurrency, 2)
        XCTAssertEqual(capacity?.pageSize, 400)
    }

    func testRecordingAgainReplacesTheOldValues() async throws {
        try await db.recordCapacity(host: "https://slow.example", concurrency: 2, pageSize: 400)
        try await db.recordCapacity(host: "https://slow.example", concurrency: 4, pageSize: 800)
        let capacity = try await db.capacity(host: "https://slow.example")
        XCTAssertEqual(capacity?.concurrency, 4)
        XCTAssertEqual(capacity?.pageSize, 800)
    }

    /// A run that learned about one of the two must not wipe what another run knew about the
    /// other — a crawl has an opinion on concurrency and none at all on page size.
    func testRecordingOneNumberLeavesTheOtherAlone() async throws {
        try await db.recordCapacity(host: "https://slow.example", concurrency: 2, pageSize: 400)
        try await db.recordCapacity(host: "https://slow.example", concurrency: 3)
        var capacity = try await db.capacity(host: "https://slow.example")
        XCTAssertEqual(capacity?.concurrency, 3)
        XCTAssertEqual(capacity?.pageSize, 400, "the page size survived a concurrency-only update")

        try await db.recordCapacity(host: "https://slow.example", pageSize: 900)
        capacity = try await db.capacity(host: "https://slow.example")
        XCTAssertEqual(capacity?.concurrency, 3)
        XCTAssertEqual(capacity?.pageSize, 900)
    }

    func testRecordingNothingIsANoOp() async throws {
        try await db.recordCapacity(host: "https://slow.example")
        let capacity = try await db.capacity(host: "https://slow.example")
        XCTAssertNil(capacity, "a call with nothing to say should not create a row")
    }

    /// Hosts are independent: one weak box must not drag down a healthy one.
    func testHostsAreKeptApart() async throws {
        try await db.recordCapacity(host: "https://slow.example", concurrency: 1, pageSize: 100)
        try await db.recordCapacity(host: "https://fast.example", concurrency: 8, pageSize: 2_000)
        let slow = try await db.capacity(host: "https://slow.example")
        let fast = try await db.capacity(host: "https://fast.example")
        XCTAssertEqual(slow?.pageSize, 100)
        XCTAssertEqual(fast?.pageSize, 2_000)
    }
}
