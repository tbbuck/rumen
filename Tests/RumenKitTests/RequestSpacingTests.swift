import XCTest
import RumenKit

/// Pacing: how fast requests are *begun*, which is separate from how many run at once.
///
/// An OGC walk asks one question per feature type and a size probe makes the server plan a
/// whole query, so the burst is what a small endpoint feels. These measure the gaps at the
/// transport rather than trusting the setting to be read.
final class RequestSpacingTests: XCTestCase {

    private let root = URL(string: "https://wfs.example.gov.uk/geoserver/ows")!

    private func client(_ transport: StubTransport, concurrency: Int = 4) -> ArcGISClient {
        ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 1, baseDelay: 0),
                     maxConcurrentPerHost: concurrency)
    }

    /// Gaps between consecutive request starts, in seconds.
    private func gaps(_ transport: StubTransport) -> [TimeInterval] {
        let times = transport.startTimes
        guard times.count > 1 else { return [] }
        return zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }
    }

    func testSpacingHoldsRequestsApart() async throws {
        let transport = StubTransport(reply: .json("{}"))
        let spacing: TimeInterval = 0.08
        let connection = ServerConnection(rootURL: root, minRequestSpacing: spacing)
        let client = client(transport)

        for _ in 0..<5 {
            _ = try await client.request(.get, url: root, server: connection)
        }

        XCTAssertEqual(transport.count, 5)
        // Timing is measured, so allow the scheduler some slack below the nominal gap.
        for gap in gaps(transport) {
            XCTAssertGreaterThan(gap, spacing * 0.7, "requests went out \(gap)s apart, closer than \(spacing)s")
        }
    }

    /// The point of the exercise: several requests in flight at once must still be *started*
    /// a gap apart, rather than all reading the same "last start" and going together.
    func testConcurrentRequestsAreStillPaced() async throws {
        let transport = StubTransport(reply: .json("{}"))
        let spacing: TimeInterval = 0.08
        let connection = ServerConnection(rootURL: root, minRequestSpacing: spacing)
        let client = client(transport, concurrency: 4)

        let url = root
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask { _ = try? await client.request(.get, url: url, server: connection) }
            }
        }

        XCTAssertEqual(transport.count, 6)
        for gap in gaps(transport) {
            XCTAssertGreaterThan(gap, spacing * 0.7, "a burst got through: \(gaps(transport))")
        }
    }

    /// Unpaced by default, so ArcGIS downloads keep the throughput the adaptive limits found.
    func testNoSpacingByDefault() async throws {
        let transport = StubTransport(reply: .json("{}"))
        let connection = ServerConnection(rootURL: root)
        let client = client(transport)

        let started = Date()
        for _ in 0..<5 {
            _ = try await client.request(.get, url: root, server: connection)
        }
        XCTAssertLessThan(-started.timeIntervalSinceNow, 0.5, "an unpaced server must not be slowed")
    }

    /// An OGC server is paced from its record; an ArcGIS one is not.
    func testOGCServersArePacedByTheirRecord() {
        let ogc = ServerRecord(id: 1, rootURL: root, friendlyName: "WFS", kind: .ogc)
        XCTAssertEqual(ogc.connection().minRequestSpacing, ServerConnection.ogcRequestSpacing)

        let arcgis = ServerRecord(id: 2, rootURL: root, friendlyName: "REST", kind: .arcgis)
        XCTAssertEqual(arcgis.connection().minRequestSpacing, 0)
    }
}
