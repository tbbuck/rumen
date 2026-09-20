import XCTest
import RumenKit

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

    // MARK: - Proxies in front of ArcGIS

    /// A proxy that hands back the server's answer as a *string* (an ASP.NET action returning
    /// `String`, asked for `application/json`): the body is a JSON string holding the document.
    private func doubleEncode(_ json: String) -> Data {
        try! JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])
    }

    func testADoubleEncodedBodyIsUnwrapped() async throws {
        let body = doubleEncode(#"{"currentVersion":10.81,"folders":["A"],"services":[{"name":"Census","type":"MapServer"}]}"#)
        XCTAssertEqual(body.first, 0x22, "the proxy's body really is a quoted string")
        let transport = StubTransport(reply: StubTransport.Reply(body: body))
        let listing = try await client(transport).serviceDirectory(server).value
        XCTAssertEqual(listing.currentVersion, 10.81)
        XCTAssertEqual(listing.folders, ["A"])
        XCTAssertEqual(listing.services.first?.name, "Census")
    }

    func testADoubleEncodedErrorEnvelopeIsStillAnError() async throws {
        let transport = StubTransport(reply: StubTransport.Reply(body: doubleEncode(#"{"error":{"code":499,"message":"Token Required","details":[]}}"#)))
        do {
            _ = try await client(transport).serviceDirectory(server)
            XCTFail("expected the wall")
        } catch ArcGISClientError.tokenRequired(let code, let message, _) {
            XCTAssertEqual(code, 499)
            XCTAssertEqual(message, "Token Required")
        }
    }

    func testOnlyAWrappedDocumentIsUnwrapped() {
        func round(_ text: String) -> String { String(decoding: ArcGISClient.unwrapJSONString(Data(text.utf8)), as: UTF8.self) }
        XCTAssertEqual(round(#""{\"a\":1}""#), #"{"a":1}"#)
        XCTAssertEqual(round(#""[1,2]""#), "[1,2]")
        XCTAssertEqual(round(#"{"a":1}"#), #"{"a":1}"#, "an ordinary document is untouched")
        XCTAssertEqual(round(#""hello""#), #""hello""#, "a string that is not a document is untouched")
        XCTAssertEqual(round("<Capabilities/>"), "<Capabilities/>")
        XCTAssertEqual(round(#""unterminated"#), #""unterminated"#)
        // A PBF body is binary and never mistaken for one: it neither begins with a quote nor parses.
        let pbf = Data([0x0A, 0x22, 0x08, 0x01, 0x12, 0xFF])
        XCTAssertEqual(ArcGISClient.unwrapJSONString(pbf), pbf)
    }

    /// A proxy that routes only GET answers `405 Allow: GET` to the POSTed query; the request
    /// goes out again as a GET, and the origin is remembered so the next one skips the POST.
    func testAPostRefusedWith405IsRetriedAsAGetAndRemembered() async throws {
        let transport = StubTransport { request, _ in
            request.httpMethod == "POST" ? .json("", status: 405) : .json(#"{"count":349114}"#)
        }
        let client = self.client(transport)
        let layer = root.appendingPathComponent("Map/3")
        let count = try await client.count(server, layerURL: layer, where: "1=1")
        XCTAssertEqual(count, 349114)
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "GET"])
        let retried = try XCTUnwrap(transport.last)
        XCTAssertEqual(retried.url?.absoluteString, layer.absoluteString + "/query?f=json&returnCountOnly=true&where=1%3D1",
                       "the form body became the query string")
        XCTAssertNil(retried.httpBody)
        let origins = await client.postRefusingOrigins
        XCTAssertEqual(origins, ["https://sampleserver6.arcgisonline.com"])

        // The second query goes straight out as a GET.
        _ = try await client.count(server, layerURL: layer, where: "1=1")
        XCTAssertEqual(transport.requests.map(\.httpMethod), ["POST", "GET", "GET"])
    }

    func testA405OnAGetIsReportedNotRetried() async throws {
        let transport = StubTransport(reply: .json("", status: 405))
        do {
            _ = try await client(transport).serviceDirectory(server)
            XCTFail("expected the status")
        } catch ArcGISClientError.http(let status, _) {
            XCTAssertEqual(status, 405)
        }
        XCTAssertEqual(transport.count, 1, "405 is not a transient failure")
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
            XCTAssertEqual(error as? ArcGISClientError, .server(code: 500, message: "json", details: [], url: url, sent: "f=json"))
        }
        XCTAssertEqual(transport.count, 1, "a permanent ArcGIS error is not retried")
    }

    /// A query is a POST, so its where clause lives in the body and never appears in the URL
    /// the error reports. It has to come back out on the error itself — without the token.
    func testRejectedQueryCarriesItsWhereClauseButNotTheToken() async throws {
        let transport = try StubTransport(reply: .fixture("s6-census-layer99.json"))
        let url = root.appendingPathComponent("Census/MapServer/3")
        let connection = ServerConnection(rootURL: root, token: "secret-token")
        let options = QueryOptions(whereClause: "ApplicationNoNew='WD/2004/0856/F'", returnGeometry: false)
        await XCTAssertThrowsErrorAsync(try await self.client(transport).features(connection, layerURL: url, options: options)) { error in
            guard case ArcGISClientError.server(_, _, _, _, let sent)? = error as? ArcGISClientError else {
                return XCTFail("expected a server error envelope, got \(String(describing: error))")
            }
            let parameters = sent ?? ""
            XCTAssertTrue(parameters.contains("where=ApplicationNoNew='WD/2004/0856/F'"), "got: \(parameters)")
            XCTAssertTrue(parameters.contains("token=<redacted>"), "got: \(parameters)")
            XCTAssertFalse(parameters.contains("secret-token"), "the token must never reach an error message")
        }
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

// MARK: - Runtime limits (M9 preferences)

/// Stays shut until opened; waiting is cancellable through `Task.sleep`.
private actor OpenGate {
    private var isOpen = false
    func open() { isOpen = true }
    func waitUntilOpen() async throws {
        while !isOpen { try await Task.sleep(for: .milliseconds(10)) }
    }
}

extension ArcGISClientTests {
    /// The preference is a ceiling, not a starting point: a host opens at one slot and earns
    /// the rest. With every response held open, nothing has succeeded, so nothing has been
    /// earned — raising the ceiling alone must not let the waiters through.
    func testRaisingTheCeilingAloneDoesNotOpenTheGate() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        let gate = OpenGate()
        transport.gate = { _ in try await gate.waitUntilOpen() }
        let client = client(transport, concurrency: 1)
        let server = self.server
        let tasks = (0..<3).map { _ in Task { _ = try await client.serviceDirectory(server) } }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.count, 1, "one in flight, two waiting behind the learned cap of 1")

        await client.setLimits(maxConcurrentPerHost: 3, retry: RetryPolicy(maxAttempts: 2, baseDelay: 0))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(transport.count, 1, "the ceiling rose, but no response has proved the host can take more")

        let limits = await client.limits
        XCTAssertEqual(limits.maxConcurrentPerHost, 3)
        XCTAssertEqual(limits.retry.maxAttempts, 2)
        await gate.open()
        for task in tasks { _ = try await task.value }
    }

    /// Clean responses earn slots: the cap doubles each round while in slow start, so a healthy
    /// host reaches a ceiling of 4 within a handful of requests.
    func testCleanResponsesClimbToTheCeiling() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        let client = client(transport, concurrency: 4)
        let host = ArcGISURL.origin(of: root)
        var limit = await client.concurrencyLimit(forHost: host)
        XCTAssertEqual(limit, 1, "a host starts at one slot")

        for _ in 0..<6 { _ = try await client.serviceDirectory(server) }

        limit = await client.concurrencyLimit(forHost: host)
        XCTAssertEqual(limit, 4, "six clean responses should have reached the ceiling")
    }

    /// A host that pushes back loses half its cap.
    func testPushbackHalvesTheCap() async throws {
        let fixture = try StubTransport.Reply.fixture("s6-root.json")
        // Eight clean answers to climb on, then the host starts refusing.
        let transport = StubTransport { _, index in
            index <= 8 ? fixture : StubTransport.Reply.json("{}", status: 503)
        }
        let client = client(transport, attempts: 1, concurrency: 8)
        let host = ArcGISURL.origin(of: root)
        for _ in 0..<8 { _ = try await client.serviceDirectory(server) }
        let before = await client.concurrencyLimit(forHost: host)
        XCTAssertEqual(before, 8, "clean responses reach the ceiling")

        _ = try? await client.serviceDirectory(server)

        let after = await client.concurrencyLimit(forHost: host)
        XCTAssertEqual(after, 4, "503 is the host saying too much; the cap halves")
    }

    /// A lowered preference clamps a cap that had already climbed above it.
    func testLoweringTheCeilingClampsALearnedCap() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        let client = client(transport, concurrency: 6)
        let host = ArcGISURL.origin(of: root)
        for _ in 0..<8 { _ = try await client.serviceDirectory(server) }
        let climbed = await client.concurrencyLimit(forHost: host)
        XCTAssertEqual(climbed, 6)

        await client.setLimits(maxConcurrentPerHost: 2, retry: RetryPolicy(maxAttempts: 2, baseDelay: 0))
        let clamped = await client.concurrencyLimit(forHost: host)
        XCTAssertEqual(clamped, 2, "the learned cap follows the ceiling down")
    }

    /// A remembered cap skips the climb, but never outruns the user's ceiling.
    func testSeedingACapSkipsTheClimbButRespectsTheCeiling() async throws {
        let transport = try StubTransport(reply: .fixture("s6-root.json"))
        let client = client(transport, concurrency: 4)
        let host = ArcGISURL.origin(of: root)
        await client.seedConcurrency(3, forHost: host)
        let seeded = await client.concurrencyLimit(forHost: host)
        XCTAssertEqual(seeded, 3)

        await client.seedConcurrency(99, forHost: host)
        let clamped = await client.concurrencyLimit(forHost: host)
        XCTAssertEqual(clamped, 4, "clamped to the ceiling")
    }

    // MARK: - Timeouts

    /// A flat timeout is wrong twice over: too mean for a big page, far too patient for the
    /// small one asked for precisely because the server is struggling.
    func testTheTimeoutFollowsWhatWasAskedFor() {
        XCTAssertEqual(ArcGISClient.timeout(forFeatures: nil), 120, "metadata keeps the default")
        XCTAssertEqual(ArcGISClient.timeout(forFeatures: 0), 120)
        // The fixed part is generous because a server's per-request cost often is too: Cornwall's
        // planning polygons take 30–40s before the first byte at any page size, and a base that
        // only suited a fast server would time those out and be read as the page being too big.
        XCTAssertEqual(ArcGISClient.timeout(forFeatures: 100), 95)
        XCTAssertEqual(ArcGISClient.timeout(forFeatures: 2_000), 190)
        XCTAssertEqual(ArcGISClient.timeout(forFeatures: 100_000), 300, "capped, however greedy the page")
        XCTAssertLessThan(ArcGISClient.timeout(forFeatures: 100), ArcGISClient.timeout(forFeatures: 2_000))
    }

    func testAPagedQueryCarriesItsSizeAsTheTimeoutHint() {
        var options = QueryOptions(whereClause: "1=1")
        XCTAssertNil(options.pagedCount, "an unbounded query has no size to go on")
        options.count = 500
        XCTAssertEqual(options.pagedCount, 500)

        var byIDs = QueryOptions(whereClause: "1=1")
        byIDs.objectIDs = Array(1...42)
        XCTAssertEqual(byIDs.pagedCount, 42, "an id list is as bounded as a page size")
    }

    // MARK: - Retry-After

    func testRetryAfterParsesSecondsAndRejectsNonsense() {
        XCTAssertEqual(ArcGISClient.retryAfter("5"), 5)
        XCTAssertEqual(ArcGISClient.retryAfter("  30 "), 30)
        XCTAssertNil(ArcGISClient.retryAfter(nil))
        XCTAssertNil(ArcGISClient.retryAfter(""))
        XCTAssertNil(ArcGISClient.retryAfter("0"), "a zero wait is no wait")
        XCTAssertNil(ArcGISClient.retryAfter("-5"))
        XCTAssertNil(ArcGISClient.retryAfter("3600"), "an hour is too long to trust; back off our own way")
        XCTAssertNil(ArcGISClient.retryAfter("soon"))
    }

    func testRetryAfterParsesAnHTTPDate() {
        let soon = Date().addingTimeInterval(20)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let parsed = try? XCTUnwrap(ArcGISClient.retryAfter(formatter.string(from: soon)))
        XCTAssertEqual(parsed ?? 0, 20, accuracy: 2)
        XCTAssertNil(ArcGISClient.retryAfter(formatter.string(from: Date().addingTimeInterval(-60))),
                     "a date in the past is not a wait")
    }
}
