import XCTest
import Foundation
import RumenKit

/// The WGS 84 box kept beside a native extent: taken as it stands when the server already
/// reports degrees, and absent otherwise. Nothing is reprojected.
final class SpatialExtentTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
    }

    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func extent(_ json: String) throws -> Extent {
        try ArcGISJSON.decode(Extent.self, from: Data(json.utf8))
    }

    func testAWGS84ExtentIsCopiedAndClamped() throws {
        let e = try extent(#"{"xmin":-7.57,"ymin":49.96,"xmax":1.68,"ymax":58.64,"spatialReference":{"wkid":4326}}"#)
        let box = try XCTUnwrap(BoundingBox.wgs84(of: e, wkid: nil))
        XCTAssertEqual(box, BoundingBox(minX: -7.57, minY: 49.96, maxX: 1.68, maxY: 58.64))
        let beyond = try extent(#"{"xmin":-190,"ymin":-91,"xmax":190,"ymax":91,"spatialReference":{"wkid":4326}}"#)
        XCTAssertEqual(BoundingBox.wgs84(of: beyond, wkid: nil), .world)
    }

    func testDegreesTaggedAsMetresAreReadAsDegrees() throws {
        // ArcGIS Online quirk seen on the ONS server: lon/lat values under a 3857 tag.
        let e = try extent(#"{"xmin":0.155934,"ymin":52.362653,"xmax":1.739635,"ymax":52.974449,"spatialReference":{"wkid":3857}}"#)
        let box = try XCTUnwrap(BoundingBox.wgs84(of: e, wkid: 3857))
        XCTAssertEqual(box.minX, 0.155934, accuracy: 1e-6)
        XCTAssertEqual(box.maxY, 52.974449, accuracy: 1e-6)
    }

    /// The point of the change: a projected extent used to go through PROJ, 10 ms a time, for
    /// every service and layer a crawl touched. It now has no box at all.
    func testAProjectedExtentHasNoBox() throws {
        let mercator = try extent(#"{"xmin":-13240129.68,"ymin":3994281.99,"xmax":-13106722.93,"ymax":4101417.51,"spatialReference":{"wkid":102100,"latestWkid":3857}}"#)
        XCTAssertNil(BoundingBox.wgs84(of: mercator, wkid: nil), "genuine Web Mercator metres")
        let nationalGrid = try extent(#"{"xmin":530000,"ymin":180000,"xmax":531000,"ymax":181000,"spatialReference":{"wkid":27700}}"#)
        XCTAssertNil(BoundingBox.wgs84(of: nationalGrid, wkid: 27700))
        // In degrees, but not WGS 84: telling a geographic reference from a projected one is
        // PROJ's knowledge, and a datum is not something to wave through on a guess.
        let nad83 = try extent(#"{"xmin":-179.62,"ymin":17.88,"xmax":-65.24,"ymax":71.41,"spatialReference":{"wkid":4269,"latestWkid":4269}}"#)
        XCTAssertNil(BoundingBox.wgs84(of: nad83, wkid: nil))
    }

    func testEmptyOrUnknownGivesNil() throws {
        let empty = try extent(#"{"xmin":"NaN","ymin":"NaN","xmax":"NaN","ymax":"NaN","spatialReference":{"wkid":4326}}"#)
        XCTAssertNil(BoundingBox.wgs84(of: empty, wkid: nil))
        let unknownCRS = try extent(#"{"xmin":0,"ymin":0,"xmax":1,"ymax":1,"spatialReference":{"wkid":999999}}"#)
        XCTAssertNil(BoundingBox.wgs84(of: unknownCRS, wkid: nil))
        let noSR = try extent(#"{"xmin":0,"ymin":0,"xmax":1,"ymax":1}"#)
        XCTAssertNil(BoundingBox.wgs84(of: noSR, wkid: nil))
        XCTAssertNil(BoundingBox.wgs84(of: nil, wkid: 4326))
    }

    func testStoredOnLayerAndService() async throws {
        let server = try await db.addServer(rootURL: URL(string: "https://x.example/arcgis/rest/services")!, friendlyName: "x")
        let svc = try await db.upsertServices(serverID: server.id, rootURL: server.rootURL, folderPath: "",
                                              entries: [.init(name: "Census", type: "MapServer")])[0]
        let rawService = try Fixtures.data("s6-census-mapserver.json")
        let info = try ArcGISJSON.decode(ServiceInfo.self, from: rawService)
        let box = BoundingBox(minX: -179.6, minY: 17.9, maxX: -65.2, maxY: 71.4)
        try await db.updateService(id: svc.id, info: info, raw: rawService, extentWGS84: box)
        let storedService = try await db.service(id: svc.id)
        XCTAssertEqual(storedService.extentWGS84, box)

        let layer = try await db.upsertLayers(serviceID: svc.id, layers: info.layers, tables: [])[3]
        let rawLayer = try Fixtures.data("s6-census-layer3.json")
        let layerInfo = try ArcGISJSON.decode(LayerInfo.self, from: rawLayer)
        try await db.updateLayer(id: layer.id, info: layerInfo, raw: rawLayer, extentWGS84: box)
        let storedLayer = try await db.layer(id: layer.id)
        XCTAssertEqual(storedLayer.extentWGS84, box)

        // A re-crawl with no box clears it: a stale one would outlive the extent it came from.
        try await db.updateLayer(id: layer.id, info: layerInfo, raw: rawLayer, extentWGS84: nil)
        let cleared = try await db.layer(id: layer.id)
        XCTAssertNil(cleared.extentWGS84)
    }
}
