import XCTest
import RumenKit

/// Reading an item id out of the viewer URLs people actually paste.
final class PortalURLTests: XCTestCase {

    private let id = "c4ffa2d7d99949b185c6d622a0f9d8ab"

    func testWebAppBuilderURL() throws {
        let ref = try XCTUnwrap(PortalURL.parse("https://cherwell.maps.arcgis.com/apps/webappviewer/index.html?id=\(id)"))
        XCTAssertEqual(ref.itemID, id)
        XCTAssertEqual(ref.portal.absoluteString, "https://cherwell.maps.arcgis.com")
        XCTAssertEqual(ref.itemURL.absoluteString,
                       "https://cherwell.maps.arcgis.com/sharing/rest/content/items/\(id)")
        XCTAssertEqual(ref.dataURL.absoluteString,
                       "https://cherwell.maps.arcgis.com/sharing/rest/content/items/\(id)/data")
    }

    func testTheOtherQueryKeys() throws {
        let shapes = [
            "https://org.maps.arcgis.com/apps/instant/sidebar/index.html?appid=\(id)",
            "https://org.maps.arcgis.com/home/webmap/viewer.html?webmap=\(id)",
            "https://org.maps.arcgis.com/home/item.html?id=\(id)",
        ]
        for text in shapes {
            XCTAssertEqual(PortalURL.parse(text)?.itemID, id, text)
        }
    }

    /// Dashboards and Experience Builder put the id in the path.
    func testIDInThePath() throws {
        let ref = try XCTUnwrap(PortalURL.parse("https://org.maps.arcgis.com/apps/dashboards/\(id)"))
        XCTAssertEqual(ref.itemID, id)
    }

    /// Enterprise serves the portal under a prefix, which the sharing URL must keep.
    func testEnterprisePortalPrefix() throws {
        let ref = try XCTUnwrap(PortalURL.parse("https://gis.example.gov.uk/portal/apps/webappviewer/index.html?id=\(id)"))
        XCTAssertEqual(ref.portal.absoluteString, "https://gis.example.gov.uk/portal")
        XCTAssertEqual(ref.itemURL.absoluteString,
                       "https://gis.example.gov.uk/portal/sharing/rest/content/items/\(id)")
    }

    func testNotAnItemURL() {
        XCTAssertNil(PortalURL.parse("https://sampleserver6.arcgisonline.com/arcgis/rest/services"), "a REST root")
        XCTAssertNil(PortalURL.parse("https://org.maps.arcgis.com/apps/webappviewer/index.html?id=map"),
                     "an id must be 32 hex characters")
        XCTAssertNil(PortalURL.parse("https://org.maps.arcgis.com/apps/webappviewer/index.html"), "no id at all")
        XCTAssertNil(PortalURL.parse("not a url"))
        XCTAssertNil(PortalURL.parse("ftp://org.maps.arcgis.com/apps/x/\(id)"), "only http(s)")
    }
}
