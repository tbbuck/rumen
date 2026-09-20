import XCTest
import Foundation
import RumenKit

/// Opt-in network tests over the real `ArcGISClient.features` path against a live ArcGIS
/// Online service (see `claude-scripts/live_test.sh`). They exist because a hand-built curl
/// proves nothing about what the app sends: only the client's own encoder, headers and POST
/// body can say whether a quoted string literal survives the trip.
final class LiveWhereClauseTests: XCTestCase {

    /// Wealden's planning register: a public, token-free FeatureServer with a string key field.
    private static let layerURL = URL(string: "https://services-eu1.arcgis.com/tkXKKODNioZnpNW8/arcgis/rest/services/WDC_planning_applications_(public_view)/FeatureServer/0")!

    private func liveClient() throws -> (ArcGISClient, ServerConnection) {
        guard ProcessInfo.processInfo.environment["ARCGIS_LIVE"] == "1" else {
            throw XCTSkip("set ARCGIS_LIVE=1 to run against the network")
        }
        return (ArcGISClient(), ServerConnection(rootURL: Self.layerURL))
    }

    /// An ASCII-quoted string literal goes through `QueryOptions` → `formEncode` → POST body
    /// and comes back with the row, so nothing in the client mangles the quotes.
    func testStraightQuotedLiteralReturnsTheRow() async throws {
        let (client, server) = try liveClient()
        let options = QueryOptions(whereClause: "ApplicationNoNew='WD/2004/0856/F'",
                                   outFields: ["ApplicationNoNew", "AddressNew"],
                                   returnGeometry: false)
        let (set, _) = try await client.features(server, layerURL: Self.layerURL, options: options)
        XCTAssertFalse(set.features.isEmpty, "a straight-quoted literal must reach the server intact")
        for feature in set.features {
            XCTAssertEqual(feature.attributes["ApplicationNoNew"], .string("WD/2004/0856/F"))
        }
    }

    /// The same clause with a space either side of the operator: `formEncode` sends `%20`
    /// rather than `+` in a form body, and the server must still accept it.
    func testSpacedOperatorSurvivesFormEncoding() async throws {
        let (client, server) = try liveClient()
        let options = QueryOptions(whereClause: "ApplicationNoNew = 'WD/2004/0856/F'",
                                   outFields: ["ApplicationNoNew"], returnGeometry: false)
        let (set, _) = try await client.features(server, layerURL: Self.layerURL, options: options)
        XCTAssertFalse(set.features.isEmpty, "%20 in a form body must not break the clause")
    }

    /// A clause the server rejects must name itself in the error. A query is a POST, so before
    /// `sent` the message carried only the endpoint URL and a 400 was undiagnosable.
    func testRejectedClauseAppearsInTheError() async throws {
        let (client, server) = try liveClient()
        let options = QueryOptions(whereClause: "ApplicationNoNew=\"WD/2004/0856/F\"",
                                   outFields: ["ApplicationNoNew"], returnGeometry: false)
        do {
            _ = try await client.features(server, layerURL: Self.layerURL, options: options)
            XCTFail("a double-quoted literal is an identifier reference and must be rejected")
        } catch let error as ArcGISClientError {
            guard case .server(_, _, _, _, let sent) = error else {
                return XCTFail("expected a server error envelope, got \(error)")
            }
            let sentParameters = try XCTUnwrap(sent)
            XCTAssertTrue(sentParameters.contains("where=ApplicationNoNew=\"WD/2004/0856/F\""),
                          "the rejected clause must be readable in the error, got: \(sentParameters)")
            XCTAssertTrue(error.description.contains("ApplicationNoNew"),
                          "the description must carry it too, got: \(error.description)")
        }
    }
}
