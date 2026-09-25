import XCTest
import Foundation
import RumenKit

/// Opt-in: proves a server's "don't verify the certificate" setting actually waives the check,
/// on both request paths and through the client, and that nothing else is waived with it.
/// Uses badssl.com's deliberately broken hosts; skipped without `ARCGIS_LIVE=1`.
final class LiveTLSTests: XCTestCase {

    private static let broken = [
        "https://self-signed.badssl.com/",
        "https://expired.badssl.com/",
        "https://wrong.host.badssl.com/",
        "https://untrusted-root.badssl.com/",
    ]

    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["ARCGIS_LIVE"] == "1" else {
            throw XCTSkip("set ARCGIS_LIVE=1 to run against the network")
        }
    }

    private func request(_ text: String) -> URLRequest {
        var request = URLRequest(url: URL(string: text)!)
        request.timeoutInterval = 30
        return request
    }

    /// The control: an ordinary transport refuses every one of them, so the waiver below is
    /// what makes the difference rather than the hosts having been fixed.
    func testAnOrdinaryTransportRefusesBrokenCertificates() async throws {
        try requireLive()
        let transport = URLSessionTransport()
        for host in Self.broken {
            do {
                _ = try await transport.perform(request(host))
                XCTFail("\(host) was accepted with verification on")
            } catch {
                // Refused, as it should be.
            }
        }
    }

    func testAnInsecureTransportAcceptsThemOnBothPaths() async throws {
        try requireLive()
        let transport = URLSessionTransport(proxy: nil, insecure: true)
        for host in Self.broken {
            let (_, plain) = try await transport.perform(request(host))
            XCTAssertEqual(plain.statusCode, 200, "\(host), plain")
            let (_, streamed) = try await transport.perform(request(host)) { _ in }
            XCTAssertEqual(streamed.statusCode, 200, "\(host), streamed")
        }
    }

    /// End to end: the setting on a connection reaches the transport the client picks, and a
    /// second connection to the same box without it is still checked.
    func testTheClientWaivesOnlyForTheServerThatAsks() async throws {
        try requireLive()
        let client = ArcGISClient()
        let root = URL(string: "https://self-signed.badssl.com/")!
        _ = try await client.fetch(root: root, params: [:], server: ServerConnection(rootURL: root, insecureTLS: true),
                                   maxAttempts: 1)
        do {
            _ = try await client.fetch(root: root, params: [:], server: ServerConnection(rootURL: root), maxAttempts: 1)
            XCTFail("a connection without the setting was waived too")
        } catch let error as ArcGISClientError {
            guard case .transport = error else { return XCTFail("expected the TLS failure, got \(error)") }
        }
    }
}
