import XCTest
import Foundation
import RumenKit

/// Opt-in: proves a per-server proxy actually carries the traffic, rather than the setting
/// being stored and quietly ignored. Needs a proxy listening on `PROXY_URL`
/// (default `http://localhost:3128`), and is skipped without `ARCGIS_LIVE=1`.
final class LiveProxyTests: XCTestCase {

    private var proxy: String {
        ProcessInfo.processInfo.environment["PROXY_URL"] ?? "http://localhost:3128"
    }

    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["ARCGIS_LIVE"] == "1" else {
            throw XCTSkip("set ARCGIS_LIVE=1 to run against the network")
        }
    }

    /// A request through the proxy transport reaches the internet and comes back.
    func testProxiedTransportFetches() async throws {
        try requireLive()
        let transport = try XCTUnwrap(URLSessionTransport(proxy: proxy), "the proxy setting must parse")
        let (data, response) = try await transport.perform(URLRequest(url: URL(string: "https://api.ipify.org")!))
        XCTAssertEqual(response.statusCode, 200)
        let address = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(address.isEmpty, "the proxy returned an empty body")
    }

    /// Pointed at a port nothing is listening on, the request must fail rather than quietly
    /// going direct — which is the failure mode that would make the whole setting a lie.
    func testProxiedTransportDoesNotFallBackToDirect() async throws {
        try requireLive()
        let transport = try XCTUnwrap(URLSessionTransport(proxy: "http://127.0.0.1:9"), "port 9 discards")
        do {
            _ = try await transport.perform(URLRequest(url: URL(string: "https://api.ipify.org")!))
            XCTFail("the request went somewhere: a dead proxy must not fall back to a direct connection")
        } catch {
            // Any URLError will do; the point is that it did not succeed.
        }
    }

    /// End to end through the client: a server whose record carries a proxy is fetched through
    /// it, so the setting reaches the transport rather than stopping at the database.
    func testClientUsesTheServerProxy() async throws {
        try requireLive()
        let client = ArcGISClient()
        let root = URL(string: "https://sampleserver6.arcgisonline.com/arcgis/rest/services")!
        let connection = ServerConnection(rootURL: root, proxyURL: proxy)
        let listing = try await client.serviceDirectory(connection).value
        XCTAssertGreaterThan(listing.services.count + listing.folders.count, 0,
                             "the directory came back empty through the proxy")
    }
}
