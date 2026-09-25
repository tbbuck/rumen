import XCTest
import Foundation
import RumenKit

/// The real transport, against a loopback server. Everything else in the suite runs on
/// StubTransport, so without these the one component that actually talks to a socket — and the
/// one whose streaming path was rewritten — would have no coverage at all.
final class URLSessionTransportTests: XCTestCase {

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        return request
    }

    func testPlainPerformReturnsTheWholeBody() async throws {
        let body = Data(#"{"hello":"world"}"#.utf8)
        let server = try LoopbackServer(body: body)
        defer { server.stop() }

        let (data, response) = try await URLSessionTransport().perform(request(server.url))
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data, body)
    }

    func testStreamingReturnsTheSameBytesAndReportsProgress() async throws {
        // Big enough to arrive in several chunks, so progress is reported more than once.
        let body = Data((0..<600_000).map { UInt8($0 % 251) })
        let server = try LoopbackServer(body: body, chunkSize: 32 * 1024)
        defer { server.stop() }

        let reports = Reports()
        let (data, response) = try await URLSessionTransport().perform(request(server.url)) { progress in
            reports.append(progress)
        }

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(data.count, body.count)
        XCTAssertEqual(data, body, "a streamed body must be byte-identical to the plain one")

        let seen = reports.all
        XCTAssertGreaterThan(seen.count, 1, "progress should be reported as the body arrives, not only at the end")
        XCTAssertEqual(seen.last?.received, Int64(body.count), "the final report is the whole body")
        XCTAssertEqual(seen.last?.expected, Int64(body.count), "Content-Length was usable, so a total is shown")
        XCTAssertEqual(seen.map(\.received), seen.map(\.received).sorted(), "progress only ever goes forwards")
    }

    /// The regression this path was rewritten for: it used to read `URLSession.AsyncBytes` one
    /// `UInt8` at a time, which for a few megabytes took long enough to look like a hang. The
    /// budget is deliberately loose — the old behaviour missed it by orders of magnitude.
    func testAMultiMegabyteBodyStreamsPromptly() async throws {
        let body = Data((0..<4_000_000).map { UInt8($0 % 251) })
        let server = try LoopbackServer(body: body, chunkSize: 64 * 1024)
        defer { server.stop() }

        let started = Date()
        let (data, _) = try await URLSessionTransport().perform(request(server.url)) { _ in }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(data.count, body.count)
        XCTAssertLessThan(elapsed, 15, "4 MB over loopback took \(elapsed)s; a per-byte read is back")
    }

    func testAnEmptyBodyCompletes() async throws {
        let server = try LoopbackServer(body: Data())
        defer { server.stop() }

        let (data, response) = try await URLSessionTransport().perform(request(server.url)) { _ in }
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(data.isEmpty)
    }

    /// Two streamed requests in flight at once must not have their bodies confused: the delegate
    /// keeps one transfer per task, and this is what proves it.
    func testConcurrentStreamsDoNotCrossOver() async throws {
        let first = Data(repeating: 0xAA, count: 200_000)
        let second = Data(repeating: 0xBB, count: 300_000)
        let serverA = try LoopbackServer(body: first, chunkSize: 16 * 1024)
        let serverB = try LoopbackServer(body: second, chunkSize: 16 * 1024)
        defer { serverA.stop(); serverB.stop() }

        let transport = URLSessionTransport()
        let requestA = request(serverA.url)
        let requestB = request(serverB.url)
        async let a = transport.perform(requestA) { _ in }
        async let b = transport.perform(requestB) { _ in }
        let (resultA, resultB) = try await (a, b)

        XCTAssertEqual(resultA.0, first)
        XCTAssertEqual(resultB.0, second)
    }

    /// A proxy transport sends both kinds of request through the proxy. The loopback server
    /// stands in for it — a proxied plain-http request reaches the proxy as an absolute URI,
    /// which it answers like any other — and the target host does not exist, so a request that
    /// went direct could only fail. The streamed path used to build its session from `.default`
    /// and go direct, so every download ignored the server's proxy.
    func testBothPathsGoThroughTheProxy() async throws {
        let body = Data(#"{"via":"proxy"}"#.utf8)
        let proxy = try LoopbackServer(body: body)
        defer { proxy.stop() }
        let transport = try XCTUnwrap(URLSessionTransport(proxy: "http://127.0.0.1:\(proxy.port)"))
        let target = request(URL(string: "http://rumen-proxy-test.invalid/thing")!)

        let (plain, _) = try await transport.perform(target)
        XCTAssertEqual(plain, body, "a plain request must go through the proxy")
        let (streamed, _) = try await transport.perform(target) { _ in }
        XCTAssertEqual(streamed, body, "a streamed request must go through the proxy too")
    }

    /// Progress handlers are called from the session's delegate queue, so collect under a lock.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var reports: [TransferProgress] = []
        func append(_ progress: TransferProgress) { lock.withLock { reports.append(progress) } }
        var all: [TransferProgress] { lock.withLock { reports } }
    }
}
