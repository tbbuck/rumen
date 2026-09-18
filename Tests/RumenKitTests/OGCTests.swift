import XCTest
import Foundation
import RumenKit
import DuckDBKit

/// A stub OGC endpoint (M10) routed by the `service` and `request` parameters. It insists on
/// the endpoint's vendor parameters on every request, as a UMN MapServer needs its `map=`.
private final class StubEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var _offersWMTS = false
    private var _geoJSON = true
    private var _version100 = false
    private var _vectorWMS = false
    private var _log: [[String: String]] = []

    var offersWMTS: Bool { get { lock.withLock { _offersWMTS } } set { lock.withLock { _offersWMTS = newValue } } }
    var geoJSON: Bool { get { lock.withLock { _geoJSON } } set { lock.withLock { _geoJSON = newValue } } }
    var version100: Bool { get { lock.withLock { _version100 } } set { lock.withLock { _version100 = newValue } } }
    /// The WMS offers a GeoJSON GetMap output, as GeoServer does.
    var vectorWMS: Bool { get { lock.withLock { _vectorWMS } } set { lock.withLock { _vectorWMS = newValue } } }
    var log: [[String: String]] { lock.withLock { _log } }

    func reply(_ request: URLRequest) throws -> StubTransport.Reply {
        let params = Self.params(request.encodedParams)
        lock.withLock { _log.append(params) }
        guard params["map"] == "pa", params["accessType"] == "PA" else {
            return .json(#"{"error":"vendor parameters missing"}"#, status: 400)
        }
        func xml(_ text: String) -> StubTransport.Reply { StubTransport.Reply(body: Data(text.utf8)) }
        switch (params["service"]?.uppercased(), params["request"]) {
        case ("WFS", "GetCapabilities"):
            if version100 { return xml(OGCFixtures.wfs100) }
            return xml(geoJSON ? OGCFixtures.wfs200 : OGCFixtures.wfs200.replacingOccurrences(of: "<ows:Value>application/json</ows:Value>", with: ""))
        case ("WFS", "DescribeFeatureType"):
            return xml(OGCFixtures.describeTowns)
        case ("WFS", "GetFeature"):
            if params["resultType"] == "hits" { return xml(OGCFixtures.hits) }
            let start = Int(params["startIndex"] ?? "0") ?? 0
            let count = Int(params["count"] ?? params["maxFeatures"] ?? "5") ?? 5
            if (params["outputFormat"] ?? "").lowercased().contains("json") {
                return .json(OGCFixtures.geoJSONPage(start..<(start + count), wgs84: params["srsName"] != nil))
            }
            return xml(OGCFixtures.gmlPage(start..<(start + count)))
        case ("WMS", "GetCapabilities"):
            return xml(vectorWMS ? OGCFixtures.wms130Vector : OGCFixtures.wms130)
        case ("WMS", "GetMap"):
            if (params["format"] ?? "").lowercased().contains("json") {
                return .json(OGCFixtures.geoJSONPage(0..<5, wgs84: false))
            }
            return StubTransport.Reply(status: 200, body: OGCFixtures.png)
        case ("WMTS", "GetCapabilities"):
            return xml(offersWMTS ? OGCFixtures.wmts100 : OGCFixtures.exceptionReport)
        default:
            return xml(OGCFixtures.exceptionReport)
        }
    }

    static func params(_ encoded: String) -> [String: String] {
        var out = [String: String]()
        for pair in encoded.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            out[kv[0]] = kv.count > 1 ? kv[1] : ""
        }
        return out
    }
}

final class OGCTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!
    private var endpoint: StubEndpoint!
    private var transport: StubTransport!
    private var crawler: Crawler!
    private var engine: DownloadEngine!
    private let pasted = "https://planning.example.gov.uk/maps/LIVE/MapServer?map=pa&service=WFS&accessType=PA&request=GetFeature&outputFormat=application%2Fjson"
    private let root = "https://planning.example.gov.uk/maps/LIVE/MapServer?accessType=PA&map=pa"

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        let endpoint = StubEndpoint()
        self.endpoint = endpoint
        transport = StubTransport { request, _ in try endpoint.reply(request) }
        let client = ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 2, baseDelay: 0))
        crawler = Crawler(client: client, database: db)
        engine = DownloadEngine(client: client, database: db, crawler: crawler,
                                stagingDirectory: scratch.appendingPathComponent("staging"), concurrency: 2)
    }

    override func tearDownWithError() throws {
        engine = nil; crawler = nil; db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - URLs

    func testPastedURLReducesToTheEndpointWithItsVendorParameters() throws {
        let location = try OGCURL.parse(pasted)
        XCTAssertEqual(location.rootURL.absoluteString, root)
        XCTAssertEqual(location.serviceHint, .wfs)
        XCTAssertNil(location.layerName)
        XCTAssertFalse(location.isCapabilitiesDocument)

        let typed = try OGCURL.parse(root + "&service=WFS&request=GetFeature&typeNames=ms:towns,ms:notes")
        XCTAssertEqual(typed.rootURL.absoluteString, root, "the same endpoint however the parameters are ordered")
        XCTAssertEqual(typed.layerName, "ms:towns")

        let wmts = try OGCURL.parse("https://tiles.example.gov.uk/wmts/1.0.0/WMTSCapabilities.xml")
        XCTAssertTrue(wmts.isCapabilitiesDocument)
        XCTAssertEqual(wmts.serviceHint, .wmts)

        let (endpoint, vendor) = OGCURL.split(URL(string: root)!)
        XCTAssertEqual(endpoint.absoluteString, "https://planning.example.gov.uk/maps/LIVE/MapServer")
        XCTAssertEqual(vendor, ["map": "pa", "accessType": "PA"])
        let url = OGCURL.url(root: URL(string: root)!, params: ["service": "WMS", "request": "GetCapabilities"])
        XCTAssertEqual(url.absoluteString, "https://planning.example.gov.uk/maps/LIVE/MapServer?accessType=PA&map=pa&request=GetCapabilities&service=WMS")

        XCTAssertThrowsError(try OGCURL.parse("not a url at all"))
        XCTAssertThrowsError(try OGCURL.parse("ftp://host/x"))
    }

    func testCRSSpellingsAndMatrixTemplates() {
        XCTAssertEqual(OGCURL.epsgCode("EPSG:27700"), 27700)
        XCTAssertEqual(OGCURL.epsgCode("urn:ogc:def:crs:EPSG::4326"), 4326)
        XCTAssertEqual(OGCURL.epsgCode("urn:x-ogc:def:crs:EPSG:3857"), 3857)
        XCTAssertEqual(OGCURL.epsgCode("http://www.opengis.net/def/crs/EPSG/0/27700"), 27700)
        XCTAssertEqual(OGCURL.epsgCode("CRS:84"), 4326)
        XCTAssertNil(OGCURL.epsgCode("AUTO2:42001"))

        XCTAssertEqual(OGCRequests.matrixTemplate(OGCTileMatrixSet(identifier: "a", crs: "", matrixIdentifiers: ["0", "1", "2"])), "{z}")
        XCTAssertEqual(OGCRequests.matrixTemplate(OGCTileMatrixSet(identifier: "b", crs: "", matrixIdentifiers: ["EPSG:3857:0", "EPSG:3857:1"])), "EPSG:3857:{z}")
        XCTAssertNil(OGCRequests.matrixTemplate(OGCTileMatrixSet(identifier: "c", crs: "", matrixIdentifiers: ["low", "high"])))
        XCTAssertEqual(OGCRequests.getMapBBox(version: "1.3.0", crs: "EPSG:4326", minX: -3.5, minY: 50.2, maxX: -2.0, maxY: 51.0), "50.2,-3.5,51.0,-2.0")
        XCTAssertEqual(OGCRequests.getMapBBox(version: "1.1.1", crs: "EPSG:4326", minX: -3.5, minY: 50.2, maxX: -2.0, maxY: 51.0), "-3.5,50.2,-2.0,51.0")
        XCTAssertEqual(OGCRequests.getMapBBox(version: "1.3.0", crs: "EPSG:3857", minX: 1, minY: 2, maxX: 3, maxY: 4), "1.0,2.0,3.0,4.0")
    }

    // MARK: - Capabilities

    func testWFSCapabilitiesParse() throws {
        let url = URL(string: root)!
        let document = try OGCCapabilities.parse(Data(OGCFixtures.wfs200.utf8), expecting: .wfs, url: url)
        XCTAssertEqual(document.type, .wfs)
        XCTAssertEqual(document.detail.version, "2.0.0")
        XCTAssertEqual(document.detail.title, "Planning WFS")
        XCTAssertEqual(document.detail.operations, ["GetCapabilities", "DescribeFeatureType", "GetFeature"])
        XCTAssertEqual(document.detail.geoJSONFormat, "application/json")
        XCTAssertTrue(document.detail.paging)
        XCTAssertEqual(document.detail.countDefault, 2)
        XCTAssertEqual(document.layers.map(\.name), ["ms:towns", "ms:notes"])
        let towns = document.layers[0]
        XCTAssertEqual(towns.title, "Towns")
        XCTAssertEqual(towns.keywords, ["towns", "places"])
        XCTAssertEqual(towns.defaultCRS, "urn:ogc:def:crs:EPSG::27700")
        XCTAssertEqual(towns.crs.count, 3)
        XCTAssertEqual(towns.bboxWGS84, BoundingBox(minX: -3.5, minY: 50.2, maxX: -2.0, maxY: 51.0))
        XCTAssertTrue(towns.supportsWebMercator)
        XCTAssertEqual(towns.wgs84CRS, "urn:ogc:def:crs:EPSG::4326")
        XCTAssertTrue(document.layerXML[0].contains("<wfs:Name>ms:towns</wfs:Name>"))

        let old = try OGCCapabilities.parse(Data(OGCFixtures.wfs100.utf8), expecting: .wfs, url: url)
        XCTAssertEqual(old.detail.version, "1.0.0")
        XCTAssertEqual(old.detail.formats, ["GML2", "GML3"])
        XCTAssertFalse(old.detail.paging)
        XCTAssertNil(old.detail.geoJSONFormat)
        XCTAssertEqual(old.layers[0].bboxWGS84, BoundingBox(minX: -3.5, minY: 50.2, maxX: -2.0, maxY: 51.0))
        XCTAssertEqual(old.layers[0].defaultCRS, "EPSG:27700")

        XCTAssertThrowsError(try OGCCapabilities.parse(Data(OGCFixtures.wms130.utf8), expecting: .wfs, url: url)) { error in
            guard case OGCError.notCapabilities(let expected, let found, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(expected, .wfs)
            XCTAssertEqual(found, "WMS_Capabilities")
        }
        XCTAssertThrowsError(try OGCCapabilities.parse(Data(OGCFixtures.exceptionReport.utf8), expecting: .wmts, url: url)) { error in
            guard case OGCError.exception(let text, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(text, "WMTS is not enabled on this endpoint")
        }
        XCTAssertThrowsError(try OGCCapabilities.parse(Data("<html><body>Sign in</body></html>".utf8), expecting: .wms, url: url))
    }

    func testWMSCapabilitiesParseInheritsFromParentLayers() throws {
        let url = URL(string: root)!
        let document = try OGCCapabilities.parse(Data(OGCFixtures.wms130.utf8), expecting: .wms, url: url)
        XCTAssertEqual(document.detail.version, "1.3.0")
        XCTAssertEqual(document.detail.maxWidth, 2048)
        XCTAssertEqual(document.detail.formats, ["image/png", "image/jpeg", "image/geotiff"])
        XCTAssertEqual(document.detail.operations, ["GetCapabilities", "GetMap", "GetFeatureInfo"])
        XCTAssertEqual(document.layers.map(\.name), ["towns", "roads"], "only named layers are requestable")
        let towns = document.layers[0]
        XCTAssertEqual(towns.queryable, true)
        XCTAssertEqual(towns.crs, ["EPSG:27700", "EPSG:4326", "EPSG:3857"], "inherited from the enclosing layer")
        XCTAssertEqual(towns.bboxWGS84, BoundingBox(minX: -3.5, minY: 50.2, maxX: -2.0, maxY: 51.0))
        XCTAssertEqual(towns.styles, ["default"])
        XCTAssertEqual(towns.webMercatorCRS, "EPSG:3857")
        let roads = document.layers[1]
        XCTAssertEqual(roads.queryable, false)
        XCTAssertEqual(roads.bboxWGS84, BoundingBox(minX: -3.0, minY: 50.5, maxX: -2.5, maxY: 50.8), "its own box wins over the parent's")

        let old = try OGCCapabilities.parse(Data(OGCFixtures.wms111.utf8), expecting: .wms, url: url)
        XCTAssertEqual(old.detail.version, "1.1.1")
        XCTAssertEqual(old.layers[0].crs, ["EPSG:27700", "EPSG:4326"], "a space-separated SRS list is split")
        XCTAssertEqual(old.layers[0].bboxWGS84, BoundingBox(minX: -3.5, minY: 50.2, maxX: -2.0, maxY: 51.0))
    }

    func testWMTSCapabilitiesParse() throws {
        let document = try OGCCapabilities.parse(Data(OGCFixtures.wmts100.utf8), expecting: .wmts, url: URL(string: root)!)
        XCTAssertEqual(document.detail.title, "Planning tiles")
        XCTAssertEqual(document.detail.tileMatrixSets.map(\.identifier), ["webmercator", "bng"])
        XCTAssertTrue(document.detail.tileMatrixSets[0].isWebMercator)
        XCTAssertEqual(document.detail.tileMatrixSets[0].matrixIdentifiers, ["0", "1"])
        XCTAssertEqual(document.detail.tileMatrixSets[0].tileWidth, 256)
        XCTAssertEqual(OGCRequests.matrixTemplate(document.detail.tileMatrixSets[1]), "EPSG:27700:{z}")
        let layer = document.layers[0]
        XCTAssertEqual(layer.name, "basemap")
        XCTAssertEqual(layer.styles, ["default"])
        XCTAssertEqual(layer.formats, ["image/png"])
        XCTAssertEqual(layer.tileMatrixSetLinks, ["webmercator"])
        XCTAssertEqual(layer.resourceURLTemplates.count, 1)
        XCTAssertTrue(layer.supportsWebMercator)
    }

    func testDescribeFeatureTypeAndHits() throws {
        let url = URL(string: root)!
        let types = try OGCCapabilities.parseFeatureTypes(Data(OGCFixtures.describeTowns.utf8), url: url)
        XCTAssertEqual(types.map(\.name), ["towns", "notes"])
        let towns = types[0]
        XCTAssertEqual(towns.fields.map(\.name), ["msGeometry", "OBJECTID", "NAME", "POP", "WHEN"])
        XCTAssertEqual(towns.fields[0].esriType, .geometry)
        XCTAssertEqual(towns.fields[0].geometryType, "esriGeometryPoint")
        XCTAssertEqual(towns.fields[1].esriType, .integer)
        XCTAssertEqual(towns.fields[2].esriType, .string)
        XCTAssertEqual(towns.fields[4].esriType, .date)
        XCTAssertEqual(try OGCCapabilities.parseHits(Data(OGCFixtures.hits.utf8), url: url), 5)
        XCTAssertThrowsError(try OGCCapabilities.parseFeatureTypes(Data(OGCFixtures.exceptionReport.utf8), url: url))
    }

    // MARK: - Opening and assessing

    func testOpenProbesTheEndpointAndLandsOnTheFeatureType() async throws {
        let opened = try await crawler.open(pasted + "&typeNames=ms:towns")
        XCTAssertTrue(opened.isNewServer)
        XCTAssertEqual(opened.server.kind, .ogc)
        XCTAssertEqual(opened.server.rootURL.absoluteString, root)
        XCTAssertTrue(opened.problems.isEmpty)
        let services = try await db.services(serverID: opened.server.id)
        XCTAssertEqual(Set(services.map(\.type)), [.wfs, .wms], "WMTS answered with an exception report and is simply absent")
        XCTAssertEqual(opened.service?.type, .wfs)
        let layer = try XCTUnwrap(opened.layer)
        XCTAssertEqual(layer.ogcName, "ms:towns")
        XCTAssertEqual(layer.name, "Towns")
        XCTAssertEqual(layer.wkid, 27700)
        XCTAssertEqual(layer.geometryType, "esriGeometryPoint")
        XCTAssertEqual(layer.type, "Feature type")
        let fields = try await db.fields(layerID: layer.id)
        XCTAssertEqual(fields.map(\.name), ["msGeometry", "OBJECTID", "NAME", "POP", "WHEN"])
        XCTAssertEqual(fields[4].duckType, "TIMESTAMP")
        // The endpoint was first asked ?f=json, bare (decision 19), and turned it down; every OGC
        // request after that carries the vendor parameter.
        XCTAssertEqual(endpoint.log.first, ["f": "json"])
        XCTAssertTrue(endpoint.log.dropFirst().allSatisfy { $0["map"] == "pa" }, "every request carries the vendor parameter")
        let raw = try await db.layerRawJSON(id: layer.id)
        XCTAssertTrue(raw?.contains("<wfs:Name>ms:towns</wfs:Name>") == true)

        // The WFS type is extractable as paged GeoJSON; the WMS layer of the same name gets its
        // features through that WFS twin; a WMS layer with no twin is a picture.
        let wfs = try await crawler.assess(layerID: layer.id)
        XCTAssertEqual(wfs.verdict, true)
        XCTAssertEqual(wfs.transport, .geojson)
        XCTAssertEqual(wfs.strategy, .offset)
        XCTAssertEqual(wfs.pageSize, 2)
        let wmsService = try XCTUnwrap(services.first { $0.type == .wms })
        let wmsTownsFound = try await db.layer(serviceID: wmsService.id, ogcName: "towns")
        let wmsTowns = try XCTUnwrap(wmsTownsFound)
        let wms = try await crawler.assess(layerID: wmsTowns.id)
        XCTAssertEqual(wms.verdict, true)
        XCTAssertTrue(wms.viaTwin)
        XCTAssertEqual(wms.sourceLayerID, layer.id)
        XCTAssertTrue(wms.reason.contains("WFS twin ms:towns"), wms.reason)
        let storedTwin = try await db.layer(id: wmsTowns.id)
        XCTAssertEqual(storedTwin.siblingLayerID, layer.id)
        let roadsFound = try await db.layer(serviceID: wmsService.id, ogcName: "roads")
        let roads = try XCTUnwrap(roadsFound)
        let picture = try await crawler.assess(layerID: roads.id)
        XCTAssertEqual(picture.verdict, false)
        XCTAssertEqual(picture.transport, .image)
        XCTAssertTrue(picture.reason.contains("picture"))
        let count = try await crawler.probeCount(layerID: layer.id)
        XCTAssertEqual(count, 5)

        // Opening again is served from the cache.
        let before = endpoint.log.count
        let again = try await crawler.open(root + "&service=WMS&request=GetMap&layers=roads")
        XCTAssertFalse(again.isNewServer)
        XCTAssertEqual(again.layer?.ogcName, "roads")
        XCTAssertEqual(endpoint.log.count, before)

        // A refresh re-probes and keeps the layer ids.
        try await crawler.shallowCrawl(serverID: opened.server.id)
        let refreshed = try await db.layer(id: layer.id)
        XCTAssertEqual(refreshed.ogcName, "ms:towns")
        let serviceCount = try await db.services(serverID: opened.server.id).count
        XCTAssertEqual(serviceCount, 2)
    }

    func testAnEndpointThatAnswersNothingIsNotKept() async throws {
        let transport = StubTransport { _, _ in StubTransport.Reply(body: Data("<html>nothing here</html>".utf8)) }
        let crawler = Crawler(client: ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 1)), database: db)
        do {
            _ = try await crawler.open("https://nothing.example.gov.uk/cgi-bin/mapserv?map=x")
            XCTFail("expected no services")
        } catch ArcGISProbeError.nothingAnswered(_, let arcgis, let attempts) {
            XCTAssertTrue(arcgis.contains("an HTML page"), arcgis)
            XCTAssertEqual(attempts.count, 3)
        }
        let servers = try await db.servers()
        XCTAssertTrue(servers.isEmpty)
    }

    // MARK: - Downloads

    private func readBack(_ path: String) throws -> (count: Int, columns: [String], geo: String) {
        let duck = try DuckDB()
        try duck.run("INSTALL spatial;")
        try duck.run("LOAD spatial;")
        let count = Int(try duck.run("SELECT count(*) FROM read_parquet(?);", [.string(path)]).scalarString ?? "0") ?? 0
        let columns = try duck.run("SELECT column_name FROM (DESCRIBE SELECT * FROM read_parquet(?));", [.string(path)]).rows.compactMap { $0.first?.stringValue }
        let geo = try duck.run("SELECT decode(value) FROM parquet_kv_metadata(?) WHERE key::VARCHAR = 'geo';", [.string(path)]).scalarString ?? ""
        return (count, columns, geo)
    }

    private func towns() async throws -> LayerRecord {
        let opened = try await crawler.open(pasted + "&typeNames=ms:towns")
        return try XCTUnwrap(opened.layer)
    }

    func testWFSDownloadPagesGeoJSONIntoGeoParquet() async throws {
        let layer = try await towns()
        var request = DownloadRequest(layerID: layer.id, outputDirectory: scratch.appendingPathComponent("out"))
        request.outWkid = 27700
        let planned = try await engine.start(request)
        XCTAssertEqual(planned.transport, .geojson)
        XCTAssertEqual(planned.strategy, .offset)
        XCTAssertEqual(planned.outWkid, 27700)
        let chunks = try await db.chunks(downloadID: planned.id)
        XCTAssertEqual(chunks.map(\.offset), [0, 2, 4], "five features in pages of two")

        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 5)
        let path = try XCTUnwrap(record.outputPath)
        XCTAssertTrue(path.hasSuffix("/out/planning.example.gov.uk/Planning WFS/Towns.parquet"), path)
        let back = try readBack(path)
        XCTAssertEqual(back.count, 5)
        XCTAssertEqual(back.columns, ["OBJECTID", "NAME", "POP", "WHEN", "geometry"])
        XCTAssertTrue(back.geo.contains("27700"), "the CRS travels in the GeoParquet metadata: \(back.geo)")
        XCTAssertTrue(back.geo.contains("\"Point\""))
        let pages = endpoint.log.filter { $0["request"] == "GetFeature" && $0["resultType"] == nil }
        XCTAssertEqual(pages.count, 3)
        XCTAssertTrue(pages.allSatisfy { $0["outputFormat"] == "application/json" && $0["typeNames"] == "ms:towns" && $0["count"] == "2" })
        XCTAssertTrue(pages.allSatisfy { $0["srsName"] == nil }, "native coordinates are not reprojected by the server")
    }

    func testWGS84IsAskedOfTheServerWhenOffered() async throws {
        let layer = try await towns()
        var request = DownloadRequest(layerID: layer.id, outputDirectory: scratch.appendingPathComponent("out"))
        request.outWkid = 4326
        request.format = .geoJSON
        let planned = try await engine.start(request)
        XCTAssertEqual(planned.outWkid, 4326)
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        let pages = endpoint.log.filter { $0["request"] == "GetFeature" && $0["resultType"] == nil }
        XCTAssertTrue(pages.allSatisfy { $0["srsName"] == "urn:ogc:def:crs:EPSG::4326" })
        let text = try String(contentsOfFile: try XCTUnwrap(record.outputPath), encoding: .utf8)
        XCTAssertTrue(text.contains("\"Town 5\""))
    }

    func testWFSDownloadFallsBackToGML() async throws {
        endpoint.geoJSON = false
        let layer = try await towns()
        var request = DownloadRequest(layerID: layer.id, outputDirectory: scratch.appendingPathComponent("out"))
        request.outWkid = 27700
        let planned = try await engine.start(request)
        XCTAssertEqual(planned.transport, .gml)
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 5)
        let back = try readBack(try XCTUnwrap(record.outputPath))
        XCTAssertEqual(back.count, 5)
        XCTAssertTrue(back.columns.contains("NAME"))
        let pages = endpoint.log.filter { $0["request"] == "GetFeature" && $0["resultType"] == nil }
        XCTAssertTrue(pages.allSatisfy { ($0["outputFormat"] ?? "").contains("gml") })
    }

    func testOldWFSDownloadsInOneRequest() async throws {
        endpoint.version100 = true
        let layer = try await towns()
        let assessment = try await crawler.assess(layerID: layer.id)
        XCTAssertEqual(assessment.strategy, .single)
        XCTAssertEqual(assessment.transport, .gml)
        var request = DownloadRequest(layerID: layer.id, outputDirectory: scratch.appendingPathComponent("out"))
        request.outWkid = 27700
        let planned = try await engine.start(request)
        let chunks = try await db.chunks(downloadID: planned.id)
        XCTAssertEqual(chunks.count, 1)
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 5)
        let page = try XCTUnwrap(endpoint.log.last { $0["request"] == "GetFeature" })
        XCTAssertEqual(page["typeName"], "ms:towns")
        XCTAssertNil(page["count"])
        XCTAssertNil(page["startIndex"])
    }

    private func wmsLayer(_ name: String) async throws -> LayerRecord {
        _ = try await crawler.open(pasted)
        let servers = try await db.servers()
        let server = try XCTUnwrap(servers.first)
        let services = try await db.services(serverID: server.id)
        let wms = try XCTUnwrap(services.first { $0.type == .wms })
        let found = try await db.layer(serviceID: wms.id, ogcName: name)
        return try XCTUnwrap(found)
    }

    func testWMSLayerDownloadsFeaturesThroughItsWFSTwin() async throws {
        let layer = try await wmsLayer("towns")
        var request = DownloadRequest(layerID: layer.id, outputDirectory: scratch.appendingPathComponent("out"))
        request.outWkid = 27700
        let planned = try await engine.start(request)
        XCTAssertEqual(planned.layerID, layer.id, "the run belongs to the layer the user chose")
        XCTAssertEqual(planned.transport, .geojson)
        XCTAssertEqual(planned.strategy, .offset)
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 5)
        let path = try XCTUnwrap(record.outputPath)
        XCTAssertTrue(path.hasSuffix("/Planning WMS/Towns.parquet"), "named for the WMS layer: \(path)")
        XCTAssertEqual(try readBack(path).count, 5)
        let pages = endpoint.log.filter { $0["request"] == "GetFeature" && $0["resultType"] == nil }
        XCTAssertEqual(pages.count, 3, "the twin's WFS pages did the work")
        XCTAssertTrue(endpoint.log.allSatisfy { $0["request"] != "GetMap" })
    }

    func testWMSGetMapAsGeoJSONDownloadsFeatures() async throws {
        endpoint.vectorWMS = true
        let layer = try await wmsLayer("roads")   // no WFS twin; the GetMap itself gives GeoJSON
        let assessment = try await crawler.assess(layerID: layer.id)
        XCTAssertEqual(assessment.verdict, true)
        XCTAssertEqual(assessment.transport, .geojson)
        XCTAssertEqual(assessment.strategy, .single)
        XCTAssertFalse(assessment.viaTwin)
        XCTAssertTrue(assessment.reason.contains("application/json;type=geojson"), assessment.reason)

        let request = DownloadRequest(layerID: layer.id, outputDirectory: scratch.appendingPathComponent("out"))
        let planned = try await engine.start(request)
        XCTAssertEqual(planned.transport, .geojson)
        XCTAssertEqual(planned.outWkid, 3857, "Web Mercator, inherited from the enclosing layer, is preferred")
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 5)
        XCTAssertTrue(try XCTUnwrap(record.outputPath).hasSuffix("/Planning WMS/Roads.parquet"))
        let getMap = try XCTUnwrap(endpoint.log.last { $0["request"] == "GetMap" })
        XCTAssertEqual(getMap["format"], "application/json;type=geojson")
        XCTAssertEqual(getMap["layers"], "roads")
        XCTAssertEqual(getMap["crs"], "EPSG:3857")
        let fields = try await db.fields(layerID: layer.id)
        XCTAssertEqual(fields.map(\.name), ["id", "OBJECTID", "NAME", "POP", "WHEN", "geom"], "the schema came from the page itself")
    }

    func testWMSPictureIsSavedWithAWorldFile() async throws {
        let layer = try await wmsLayer("roads")   // no WFS twin, no GeoJSON GetMap: a picture only

        var features = DownloadRequest(layerID: layer.id, outputDirectory: scratch.appendingPathComponent("out"))
        features.format = .geoParquet
        do {
            _ = try await engine.start(features)
            XCTFail("a WMS layer without features cannot be written as features")
        } catch DownloadError.notExtractable(let reason) {
            XCTAssertTrue(reason.contains("picture"))
        }

        var picture = DownloadRequest(layerID: layer.id, outputDirectory: scratch.appendingPathComponent("out"))
        picture.format = .png
        let planned = try await engine.start(picture)
        XCTAssertEqual(planned.transport, .image)
        XCTAssertEqual(planned.outWkid, 3857, "Web Mercator is preferred when the layer offers it")
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        let path = try XCTUnwrap(record.outputPath)
        XCTAssertTrue(path.hasSuffix("/Planning WMS/Roads.png"), path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), OGCFixtures.png)
        let world = try String(contentsOfFile: String(path.dropLast(3)) + "pgw", encoding: .utf8)
        XCTAssertEqual(world.split(separator: "\n").count, 6)
        let getMap = try XCTUnwrap(endpoint.log.last { $0["request"] == "GetMap" })
        XCTAssertEqual(getMap["crs"], "EPSG:3857", "inherited from the enclosing layer")
        XCTAssertEqual(planned.outWkid, 3857)
        XCTAssertEqual(getMap["layers"], "roads")
        XCTAssertEqual(getMap["format"], "image/png")
        XCTAssertEqual(getMap["transparent"], "TRUE")
        XCTAssertNotNil(getMap["width"].flatMap(Int.init))
        XCTAssertNotNil(getMap["height"].flatMap(Int.init))

        // A layer with features can still be saved as a picture, in Web Mercator when offered.
        let towns = try await wmsLayer("towns")
        var tiff = DownloadRequest(layerID: towns.id, outputDirectory: scratch.appendingPathComponent("out"))
        tiff.format = .geoTIFF
        let tiffPlanned = try await engine.start(tiff)
        XCTAssertEqual(tiffPlanned.transport, .image)
        XCTAssertEqual(tiffPlanned.outWkid, 3857, "Web Mercator is preferred when the layer offers it")
        let tiffRecord = try await engine.wait(downloadID: tiffPlanned.id)
        XCTAssertEqual(tiffRecord.status, .complete, tiffRecord.error ?? "")
        XCTAssertTrue(try XCTUnwrap(tiffRecord.outputPath).hasSuffix("Towns.tif"))
        let tiffMap = try XCTUnwrap(endpoint.log.last { $0["request"] == "GetMap" })
        XCTAssertEqual(tiffMap["crs"], "EPSG:3857")
        XCTAssertEqual(tiffMap["styles"], "default")
        XCTAssertEqual(tiffMap["width"], "2048", "the server's MaxWidth caps the long side")
    }
}
