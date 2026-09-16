import XCTest
import ArcGISKit

final class ArcGISClientTests: XCTestCase {

    private let root = URL(string: "https://sampleserver6.arcgisonline.com/arcgis/rest/services")!
    private var server: ServerConnection { ServerConnection(rootURL: root) }

    private func client(_ transport: StubTransport, attempts: Int = 5, concurrency: Int = 4) -> ArcGISClient {
        ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: attempts, baseDelay: 0),
                     maxConcurrentPerHost: concurrency)
    }

    // MARK: - Headers (hard rule)

    func testDefaultHeadersAreServerOriginAndOriginSlash() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        _ = try await client(transport).serviceDirectory(server)
        let request = try XCTUnwrap(transport.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://sampleserver6.arcgisonline.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://sampleserver6.arcgisonline.com/")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), ArcGISClient.userAgent)
    }

    func testHeaderOverridesAreHonoured() async throws {
        let headers = ServerHeaders.resolve(rootURL: root, originOverride: "https://portal.example",
                                            refererOverride: "  ")
        XCTAssertEqual(headers, ServerHeaders(origin: "https://portal.example",
                                              referer: "https://sampleserver6.arcgisonline.com/"))
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        _ = try await client(transport).serviceDirectory(ServerConnection(rootURL: root, headers: headers))
        XCTAssertEqual(transport.last?.value(forHTTPHeaderField: "Origin"), "https://portal.example")
    }

    func testCookieIsSentVerbatimWithSessionCookiesOff() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        _ = try await client(transport).serviceDirectory(ServerConnection(rootURL: root, cookie: "agsession=abc; other=1"))
        let request = try XCTUnwrap(transport.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "agsession=abc; other=1")
        XCTAssertFalse(request.httpShouldHandleCookies)
        _ = try await client(transport).serviceDirectory(ServerConnection(rootURL: root, cookie: "  "))
        XCTAssertNil(transport.last?.value(forHTTPHeaderField: "Cookie"), "a blank cookie sends nothing")
    }

    // MARK: - Request building

    func testGetAddsFormatAndEncodesParams() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        _ = try await client(transport).serviceDirectory(server, folder: "Utilities")
        let request = try XCTUnwrap(transport.last)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, root.absoluteString + "/Utilities?f=json")
    }

    func testCountPostsAFormBody() async throws {
        let transport = StubTransport(reply: .json(#"{"count":305}"#))
        let layer = root.appendingPathComponent("Wildfire/FeatureServer/0")
        let count = try await client(transport).count(server, layerURL: layer, where: "STATE = 'CA' AND x>1")
        XCTAssertEqual(count, 305)
        let request = try XCTUnwrap(transport.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, layer.absoluteString + "/query")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        XCTAssertEqual(request.encodedParams, "f=json&returnCountOnly=true&where=STATE%20%3D%20%27CA%27%20AND%20x%3E1")
    }

    func testTokenIsAppendedWhenSet() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        _ = try await client(transport).serviceDirectory(ServerConnection(rootURL: root, token: "abc/+="))
        XCTAssertEqual(transport.last?.url?.query, "f=json&token=abc%2F%2B%3D")
    }

    func testCallerFormatWins() async throws {
        let transport = StubTransport(reply: .json("{}"))
        _ = try await client(transport).request(.get, url: root, params: ["f": "pbf"], server: server)
        XCTAssertEqual(transport.last?.url?.query, "f=pbf")
    }

    // MARK: - Errors

    func testHTTPErrorStatus() async throws {
        let transport = StubTransport(reply: .json("nope", status: 404))
        await XCTAssertThrowsErrorAsync(try await self.client(transport).serviceDirectory(self.server)) { error in
            XCTAssertEqual(error as? ArcGISClientError, .http(status: 404, url: self.root))
        }
        XCTAssertEqual(transport.count, 1, "404 is not retried")
    }

    func testErrorEnvelopeBecomesServerError() async throws {
        let transport = try StubTransport(reply: .fixture("s6-census-layer99.json"))
        let url = root.appendingPathComponent("Census/MapServer/99")
        await XCTAssertThrowsErrorAsync(try await self.client(transport).layerInfo(self.server, layerURL: url)) { error in
            XCTAssertEqual(error as? ArcGISClientError, .server(code: 500, message: "json", details: [], url: url))
        }
        XCTAssertEqual(transport.count, 1, "a permanent ArcGIS error is not retried")
    }

    func testTokenRequiredIsDistinct() async throws {
        let transport = StubTransport(reply: .json(#"{"error":{"code":499,"message":"Token Required","details":[]}}"#))
        await XCTAssertThrowsErrorAsync(try await self.client(transport).serviceDirectory(self.server)) { error in
            XCTAssertEqual(error as? ArcGISClientError, .tokenRequired(code: 499, message: "Token Required", url: self.root))
        }
    }

    func testHTMLBodyIsADecodingErrorWithHint() async throws {
        let transport = StubTransport(reply: .json("<html><body>Sign in</body></html>"))
        await XCTAssertThrowsErrorAsync(try await self.client(transport).serviceDirectory(self.server)) { error in
            guard case ArcGISClientError.decoding(let hint, _)? = error as? ArcGISClientError else {
                return XCTFail("expected .decoding, got \(error)")
            }
            XCTAssertTrue(hint.contains("HTML"), hint)
        }
    }

    // MARK: - Retries

    func testTransientFailuresAreRetriedThenSucceed() async throws {
        let good = try Fixtures.data("s6-root.json")
        let transport = StubTransport { _, index in
            switch index {
            case 1: return .json("busy", status: 503)
            case 2: throw URLError(.timedOut)
            case 3: return .json(#"{"error":{"code":429,"message":"Too many requests"}}"#)
            default: return .init(body: good)
            }
        }
        let dir = try await client(transport).serviceDirectory(server)
        XCTAssertEqual(dir.value.folders.count, 13)
        XCTAssertEqual(transport.count, 4)
    }

    func testGivesUpAfterMaxAttempts() async throws {
        let transport = StubTransport(reply: .json("busy", status: 503))
        await XCTAssertThrowsErrorAsync(try await self.client(transport, attempts: 3).serviceDirectory(self.server)) { error in
            XCTAssertEqual(error as? ArcGISClientError, .http(status: 503, url: self.root))
        }
        XCTAssertEqual(transport.count, 3)
    }

    // MARK: - Concurrency cap

    func testInFlightRequestsPerHostAreCapped() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        transport.delay = .milliseconds(30)
        let client = client(transport, concurrency: 3)
        let server = self.server
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { _ = try await client.serviceDirectory(server) }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(transport.count, 12)
        XCTAssertLessThanOrEqual(transport.maxConcurrent, 3)
        XCTAssertGreaterThan(transport.maxConcurrent, 1, "requests do run in parallel")
    }

    // MARK: - Encoding helpers

    func testFormEncodingIsStrictAndSorted() {
        XCTAssertEqual(ArcGISClient.formEncode(["where": "a=1 & b", "f": "json", "outFields": "*"]),
                       "f=json&outFields=%2A&where=a%3D1%20%26%20b")
        XCTAssertEqual(ArcGISClient.formEncode([:]), "")
    }
}
