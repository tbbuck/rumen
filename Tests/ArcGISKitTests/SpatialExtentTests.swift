import XCTest
import Foundation
import ArcGISKit

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

    func testRequiresSpatial() async throws {
        let e = try extent(#"{"xmin":0,"ymin":0,"xmax":1,"ymax":1,"spatialReference":{"wkid":3857}}"#)
        await XCTAssertThrowsErrorAsync(try await self.db.wgs84Extent(of: e, wkid: nil)) { error in
            XCTAssertEqual(error as? SpatialError, .notLoaded)
        }
    }

    func testWebMercatorExtentReprojects() async throws {
        try await db.loadSpatial()
        // Trailheads fixture extent: Los Angeles area in 102100 / 3857.
        let e = try extent(#"{"xmin":-13240129.68,"ymin":3994281.99,"xmax":-13106722.93,"ymax":4101417.51,"spatialReference":{"wkid":102100,"latestWkid":3857}}"#)
        let maybeBox = try await db.wgs84Extent(of: e, wkid: nil)
        let box = try XCTUnwrap(maybeBox)
        XCTAssertEqual(box.minX, -118.94, accuracy: 0.05)
        XCTAssertEqual(box.maxX, -117.74, accuracy: 0.05)
        XCTAssertEqual(box.minY, 33.70, accuracy: 0.05)
        XCTAssertEqual(box.maxY, 34.50, accuracy: 0.05)
    }

    func testBritishNationalGridReprojects() async throws {
        try await db.loadSpatial()
        let e = try extent(#"{"xmin":530000,"ymin":180000,"xmax":531000,"ymax":181000,"spatialReference":{"wkid":27700}}"#)
        let maybeBox = try await db.wgs84Extent(of: e, wkid: 27700)
        let box = try XCTUnwrap(maybeBox)
        XCTAssertEqual(box.minX, -0.13, accuracy: 0.02)   // central London
        XCTAssertEqual(box.minY, 51.50, accuracy: 0.02)
    }

    func testDegreesTaggedAsMetresAreReadAsDegrees() async throws {
        try await db.loadSpatial()
        // ArcGIS Online quirk seen on the ONS server: lon/lat values under a 3857 tag.
        let e = try extent(#"{"xmin":0.155934,"ymin":52.362653,"xmax":1.739635,"ymax":52.974449,"spatialReference":{"wkid":3857}}"#)
        let maybeBox = try await db.wgs84Extent(of: e, wkid: 3857)
        let box = try XCTUnwrap(maybeBox)
        XCTAssertEqual(box.minX, 0.155934, accuracy: 1e-6)
        XCTAssertEqual(box.maxY, 52.974449, accuracy: 1e-6)
        let realMercator = try extent(#"{"xmin":-13000,"ymin":6700000,"xmax":-12000,"ymax":6710000,"spatialReference":{"wkid":3857}}"#)
        let maybeProjected = try await db.wgs84Extent(of: realMercator, wkid: 3857)
        let projected = try XCTUnwrap(maybeProjected)
        XCTAssertEqual(projected.minX, -0.1168, accuracy: 0.001, "genuine metres still reproject")
    }

    func testGeographicExtentIsCopiedAndClamped() async throws {
        try await db.loadSpatial()
        let e = try extent(#"{"xmin":-179.62,"ymin":17.88,"xmax":-65.24,"ymax":71.41,"spatialReference":{"wkid":4269,"latestWkid":4269}}"#)
        let maybeNad83 = try await db.wgs84Extent(of: e, wkid: nil)
        let nad83 = try XCTUnwrap(maybeNad83)
        XCTAssertEqual(nad83.minX, -179.62, accuracy: 0.01, "NAD83 → WGS 84 is a sub-metre shift")
        let wgs = try extent(#"{"xmin":-190,"ymin":-91,"xmax":190,"ymax":91,"spatialReference":{"wkid":4326}}"#)
        let clamped = try await db.wgs84Extent(of: wgs, wkid: nil)
        XCTAssertEqual(clamped, .world)
    }

    func testEmptyOrUnknownGivesNil() async throws {
        try await db.loadSpatial()
        let empty = try extent(#"{"xmin":"NaN","ymin":"NaN","xmax":"NaN","ymax":"NaN","spatialReference":{"wkid":4326}}"#)
        let noBox = try await db.wgs84Extent(of: empty, wkid: nil)
        XCTAssertNil(noBox)
        let unknownCRS = try extent(#"{"xmin":0,"ymin":0,"xmax":1,"ymax":1,"spatialReference":{"wkid":999999}}"#)
        let noCRS = try await db.wgs84Extent(of: unknownCRS, wkid: nil)
        XCTAssertNil(noCRS)
        let noSR = try extent(#"{"xmin":0,"ymin":0,"xmax":1,"ymax":1}"#)
        let nothing = try await db.wgs84Extent(of: noSR, wkid: nil)
        XCTAssertNil(nothing)
    }

    func testStoredOnLayerAndService() async throws {
        try await db.loadSpatial()
        let server = try await db.addServer(rootURL: URL(string: "https://x.example/arcgis/rest/services")!, friendlyName: "x")
        let svc = try await db.upsertServices(serverID: server.id, rootURL: server.rootURL, folderPath: "",
                                              entries: [.init(name: "Census", type: "MapServer")])[0]
        let rawService = try Fixtures.data("s6-census-mapserver.json")
        let info = try ArcGISJSON.decode(ServiceInfo.self, from: rawService)
        let serviceBox = try await db.wgs84Extent(of: info.fullExtent, wkid: info.spatialReference?.effectiveWkid)
        try await db.updateService(id: svc.id, info: info, raw: rawService, extentWGS84: serviceBox)
        let storedService = try await db.service(id: svc.id)
        XCTAssertEqual(storedService.extentWGS84?.minX ?? 0, -179.6, accuracy: 0.1)

        let layer = try await db.upsertLayers(serviceID: svc.id, layers: info.layers, tables: [])[3]
        let rawLayer = try Fixtures.data("s6-census-layer3.json")
        let layerInfo = try ArcGISJSON.decode(LayerInfo.self, from: rawLayer)
        let layerBox = try await db.wgs84Extent(of: layerInfo.extent, wkid: layerInfo.spatialReference?.effectiveWkid)
        try await db.updateLayer(id: layer.id, info: layerInfo, raw: rawLayer, extentWGS84: layerBox)
        let storedLayer = try await db.layer(id: layer.id)
        XCTAssertNotNil(storedLayer.extentWGS84)
        XCTAssertEqual(storedLayer.extentWGS84?.maxY ?? 0, 71.4, accuracy: 0.1)
    }
}
