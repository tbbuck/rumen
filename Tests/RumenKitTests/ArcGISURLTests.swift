import XCTest
import RumenKit

final class ArcGISURLTests: XCTestCase {

    private let s6 = URL(string: "https://sampleserver6.arcgisonline.com/arcgis/rest/services")!

    func testRootVariants() throws {
        for text in [
            "https://sampleserver6.arcgisonline.com/arcgis/rest/services",
            "https://sampleserver6.arcgisonline.com/arcgis/rest/services/",
            "https://sampleserver6.arcgisonline.com/arcgis/rest/services?f=json",
            "HTTPS://SampleServer6.ArcGISOnline.com/arcgis/rest/services/?f=pjson#top",
            "sampleserver6.arcgisonline.com/arcgis/rest/services",
            "  https://sampleserver6.arcgisonline.com/arcgis/rest/services  \n",
        ] {
            XCTAssertEqual(try ArcGISURL.parse(text), ArcGISLocation(rootURL: s6), text)
        }
    }

    func testFolder() throws {
        let loc = try ArcGISURL.parse("https://sampleserver6.arcgisonline.com/arcgis/rest/services/Utilities?f=json")
        XCTAssertEqual(loc, ArcGISLocation(rootURL: s6, folderPath: "Utilities"))
        XCTAssertEqual(loc.folderURL.absoluteString, s6.absoluteString + "/Utilities")
        let nested = try ArcGISURL.parse("https://sampleserver6.arcgisonline.com/arcgis/rest/services/A/B/")
        XCTAssertEqual(nested.folderPath, "A/B")
        XCTAssertNil(nested.servicePath)
    }

    func testServiceAtRoot() throws {
        let loc = try ArcGISURL.parse("https://sampleserver6.arcgisonline.com/arcgis/rest/services/Census/MapServer")
        XCTAssertEqual(loc, ArcGISLocation(rootURL: s6, folderPath: nil, servicePath: "Census", serviceType: .mapServer))
        XCTAssertEqual(loc.serviceURL?.absoluteString, s6.absoluteString + "/Census/MapServer")
        XCTAssertNil(loc.layerURL)
    }

    func testServiceInFolderWithLayerAndQuery() throws {
        let loc = try ArcGISURL.parse(
            "https://sampleserver6.arcgisonline.com/arcgis/rest/services/Utilities/Geometry/GeometryServer")
        XCTAssertEqual(loc.folderPath, "Utilities")
        XCTAssertEqual(loc.servicePath, "Utilities/Geometry")
        XCTAssertEqual(loc.serviceType, .other("GeometryServer"))
        XCTAssertFalse(loc.serviceType!.hasLayers)

        let layer = try ArcGISURL.parse(
            "https://sampleserver6.arcgisonline.com/arcgis/rest/services/Sync/WildfireSync/FeatureServer/2/query?where=1%3D1&outFields=*&f=pbf")
        XCTAssertEqual(layer, ArcGISLocation(rootURL: s6, folderPath: "Sync", servicePath: "Sync/WildfireSync",
                                             serviceType: .featureServer, layerID: 2))
        XCTAssertEqual(layer.layerURL?.absoluteString, s6.absoluteString + "/Sync/WildfireSync/FeatureServer/2")
    }

    func testNonLayerSuffixesAreIgnored() throws {
        let layers = try ArcGISURL.parse("https://sampleserver6.arcgisonline.com/arcgis/rest/services/Census/MapServer/layers?f=json")
        XCTAssertEqual(layers.serviceType, .mapServer)
        XCTAssertNil(layers.layerID)
        let legend = try ArcGISURL.parse("https://sampleserver6.arcgisonline.com/arcgis/rest/services/Census/MapServer/legend")
        XCTAssertNil(legend.layerID)
    }

    func testCaseInsensitiveTypeAndRestSegments() throws {
        let loc = try ArcGISURL.parse("https://services.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/mapserver/0")
        XCTAssertEqual(loc.rootURL.absoluteString, "https://services.arcgisonline.com/ArcGIS/rest/services")
        XCTAssertEqual(loc.serviceType, .mapServer)
        XCTAssertEqual(loc.serviceType?.name, "MapServer")
        XCTAssertEqual(loc.layerID, 0)
        let mixed = try ArcGISURL.parse("https://host.example/Server/REST/Services/X/FeatureServer")
        XCTAssertEqual(mixed.rootURL.absoluteString, "https://host.example/Server/REST/Services")
        XCTAssertEqual(mixed.servicePath, "X")
    }

    func testArcGISOnlineHostedRoot() throws {
        let loc = try ArcGISURL.parse(
            "https://services3.arcgis.com/GVgbJbqm8hXASVYi/arcgis/rest/services/Trailheads/FeatureServer/0")
        XCTAssertEqual(loc.rootURL.absoluteString, "https://services3.arcgis.com/GVgbJbqm8hXASVYi/arcgis/rest/services")
        XCTAssertEqual(loc.servicePath, "Trailheads")
        XCTAssertEqual(loc.layerID, 0)
    }

    func testPortAndHttpArePreserved() throws {
        let loc = try ArcGISURL.parse("http://gis.internal:6080/arcgis/rest/services/Roads/MapServer/1")
        XCTAssertEqual(loc.rootURL.absoluteString, "http://gis.internal:6080/arcgis/rest/services")
        XCTAssertEqual(loc.origin, "http://gis.internal:6080")
    }

    func testOriginIsSchemeAndHost() {
        XCTAssertEqual(ArcGISLocation(rootURL: s6).origin, "https://sampleserver6.arcgisonline.com")
    }

    func testRejectsNonArcGISAndMalformed() {
        XCTAssertThrowsError(try ArcGISURL.parse("")) { XCTAssertEqual($0 as? ArcGISURLError, .empty) }
        XCTAssertThrowsError(try ArcGISURL.parse("https://example.com/not/arcgis")) {
            XCTAssertEqual($0 as? ArcGISURLError, .notArcGIS("https://example.com/not/arcgis"))
        }
        XCTAssertThrowsError(try ArcGISURL.parse("https://example.com/arcgis/rest/services/MapServer")) {
            XCTAssertEqual($0 as? ArcGISURLError, .notArcGIS("https://example.com/arcgis/rest/services/MapServer"))
        }
        XCTAssertThrowsError(try ArcGISURL.parse("ftp://example.com/arcgis/rest/services")) {
            XCTAssertEqual($0 as? ArcGISURLError, .malformed("ftp://example.com/arcgis/rest/services"))
        }
        XCTAssertThrowsError(try ArcGISURL.parse("not a url at all"))
    }
}
