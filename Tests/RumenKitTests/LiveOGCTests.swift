import XCTest
import Foundation
import RumenKit
import SQLiteKit

/// Opt-in network test against a real OGC endpoint (M10). Skipped unless `OGC_LIVE_URL` names
/// one (see `claude-scripts/live_ogc_test.sh`): the endpoint is opened and probed, a WFS type
/// is counted and sampled, a WMS layer is drawn once. Proves the real URLSession path with the
/// endpoint's own vendor parameters, capabilities and answers.
final class LiveOGCTests: XCTestCase {

    func testOpenSampleAndDrawARealEndpoint() async throws {
        guard let text = ProcessInfo.processInfo.environment["OGC_LIVE_URL"], !text.isEmpty else {
            throw XCTSkip("set OGC_LIVE_URL to a WMS, WFS or WMTS endpoint to run against the network")
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        let client = ArcGISClient()
        let crawler = Crawler(client: client, database: db)

        let opened = try await crawler.open(text)
        XCTAssertEqual(opened.server.kind, .ogc)
        let services = try await db.services(serverID: opened.server.id)
        XCTAssertFalse(services.isEmpty, "no service answered")
        print("services:", services.map { "\($0.type.name) \($0.ogcDetail?.version ?? "") \"\($0.name)\"" }.joined(separator: ", "))
        for problem in opened.problems { print("problem:", problem.folderPath, problem.message) }
        let connection = opened.server.connection()

        if let wfs = services.first(where: { $0.type == .wfs }), let detail = wfs.ogcDetail {
            let layers = try await db.layers(serviceID: wfs.id)
            XCTAssertFalse(layers.isEmpty)
            print("WFS types:", layers.count, "formats:", detail.formats.joined(separator: ", "), "paging:", detail.paging, "countDefault:", detail.countDefault ?? -1)
            let layer = opened.layer.flatMap { $0.serviceID == wfs.id ? $0 : nil } ?? layers[0]
            let fields = try await db.fields(layerID: layer.id)
            print("type:", layer.ogcName ?? "", "fields:", fields.map(\.name).joined(separator: ", "))
            let assessment = try await crawler.assess(layerID: layer.id)
            print("assessment:", assessment.reason)
            XCTAssertEqual(assessment.verdict, true)
            if !detail.version.hasPrefix("1.0") {
                let count = try await crawler.probeCount(layerID: layer.id)
                print("count:", count)
                XCTAssertGreaterThanOrEqual(count, 0)
            }
            let format = detail.geoJSONFormat
            let params = OGCRequests.getFeature(version: detail.version, typeName: layer.ogcName ?? "", format: format, startIndex: nil, count: 5)
            let data = try await client.fetch(root: opened.server.rootURL, params: params, server: connection)
            let geoJSON = format != nil && layer.effectiveWkid == 4326
                ? String(decoding: data, as: UTF8.self)
                : try await db.geoJSONInWGS84(data: data, fileExtension: format != nil ? "json" : "gml", sourceWkid: layer.effectiveWkid)
            let object = try JSONSerialization.jsonObject(with: Data(geoJSON.utf8)) as? [String: Any]
            let features = object?["features"] as? [Any] ?? []
            print("sample features:", features.count)
            XCTAssertLessThanOrEqual(features.count, 5)
        }

        if let wms = services.first(where: { $0.type == .wms }), let detail = wms.ogcDetail {
            let layers = try await db.layers(serviceID: wms.id)
            XCTAssertFalse(layers.isEmpty)
            print("WMS layers:", layers.count, "formats:", detail.formats.joined(separator: ", "))
            // A leaf layer (a group's own CRS may be empty); its picture is framed as the engine frames it.
            let layer = layers.first { !($0.ogcDetail?.crs.isEmpty ?? true) && layers.count == 1 || $0.layerID > 0 } ?? layers[0]
            guard let ogc = layer.ogcDetail, let name = layer.ogcName, let box = layer.extentWGS84 else { return }
            let crs = ogc.webMercatorCRS ?? ogc.wgs84CRS ?? ogc.crs.first ?? "EPSG:4326"
            let (minX, minY, maxX, maxY): (Double, Double, Double, Double)
            if OGCURL.epsgCode(crs) == 3857 {
                let a = DownloadEngine.webMercator(lon: box.minX, lat: box.minY), b = DownloadEngine.webMercator(lon: box.maxX, lat: box.maxY)
                (minX, minY, maxX, maxY) = (a.0, a.1, b.0, b.1)
            } else if let code = OGCURL.epsgCode(crs), code != 4326 {
                let corners = try await db.transform([(box.minX, box.minY), (box.maxX, box.minY), (box.maxX, box.maxY), (box.minX, box.maxY)], from: 4326, to: code)
                (minX, minY, maxX, maxY) = (corners.map(\.0).min()!, corners.map(\.1).min()!, corners.map(\.0).max()!, corners.map(\.1).max()!)
            } else {
                (minX, minY, maxX, maxY) = (box.minX, box.minY, box.maxX, box.maxY)
            }
            let assessment = try await crawler.assess(layerID: layer.id)
            print("WMS assessment:", assessment.reason)
            let bbox = OGCRequests.getMapBBox(version: detail.version, crs: crs, minX: minX, minY: minY, maxX: maxX, maxY: maxY)
            let params = OGCRequests.getMap(version: detail.version, layer: name, style: ogc.styles.first ?? "", crs: crs, bbox: bbox,
                                            width: 256, height: 256, format: detail.formats.first { $0.hasPrefix("image/png") } ?? "image/png", transparent: true)
            let data = try await client.fetch(root: opened.server.rootURL, params: params, server: connection)
            print("GetMap bytes:", data.count, "layer:", name, "crs:", crs)
            XCTAssertFalse(ArcGISClient.looksLikeXML(data), String(decoding: data.prefix(300), as: UTF8.self))
            XCTAssertGreaterThan(data.count, 0)
        }
    }
}
