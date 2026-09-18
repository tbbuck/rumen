import XCTest
import Foundation
import ArcGISKit
import SQLiteKit

/// Bodies a council proxy answers with (decision 19): the real Stratford-on-Avon planning
/// register MapServer at `/EplanningV2/API/v1/Map`, trimmed, no `rest/services` anywhere.
private enum ProxyFixtures {
    static let mapServer = #"{"currentVersion":10.81,"serviceDescription":"Planning Register Maps","mapName":"Layers","description":"","copyrightText":"","supportsDynamicLayers":true,"layers":[{"id":0,"name":"Parishes 2015","parentLayerId":-1,"defaultVisibility":true,"subLayerIds":null,"minScale":250000,"maxScale":1,"type":"Feature Layer","geometryType":"esriGeometryPolygon"},{"id":1,"name":"UNISDELIVE.UFRM_DCAPPL_POLY","parentLayerId":-1,"defaultVisibility":true,"subLayerIds":null,"minScale":8000,"maxScale":1,"type":"Feature Layer","geometryType":"esriGeometryPolygon"},{"id":2,"name":"UNISDELIVE.UFRM_APCASE_POLY","parentLayerId":-1,"defaultVisibility":true,"subLayerIds":null,"minScale":8000,"maxScale":1,"type":"Feature Layer","geometryType":"esriGeometryPolygon"},{"id":3,"name":"Map text","parentLayerId":-1,"defaultVisibility":true,"subLayerIds":null,"minScale":2000,"maxScale":1,"type":"Feature Layer","geometryType":"esriGeometryPoint"},{"id":4,"name":"Map Areas","parentLayerId":-1,"defaultVisibility":true,"subLayerIds":null,"minScale":8000,"maxScale":1,"type":"Feature Layer","geometryType":"esriGeometryPolygon"}],"tables":[],"spatialReference":{"wkid":27700,"latestWkid":27700},"singleFusedMapCache":false,"initialExtent":{"xmin":419787.46,"ymin":254585.79,"xmax":420129.52,"ymax":254776.08,"spatialReference":{"wkid":27700,"latestWkid":27700}},"fullExtent":{"xmin":393015.77,"ymin":225042.49,"xmax":463270.37,"ymax":277279.44,"spatialReference":{"wkid":27700,"latestWkid":27700}},"minScale":250000,"maxScale":1,"units":"esriMeters","supportedImageFormatTypes":"PNG32,PNG24,PNG,JPG,DIB,TIFF,EMF,PS,PDF,GIF,SVG,SVGZ,BMP","capabilities":"Map,Query,Data","supportedQueryFormats":"JSON, geoJSON","exportTilesAllowed":false,"maxRecordCount":1000,"maxImageHeight":4096,"maxImageWidth":4096,"supportedExtensions":"KmlServer"}"#

    static let layer3 = #"{"currentVersion":10.81,"id":3,"name":"Map text","type":"Feature Layer","description":"","geometryType":"esriGeometryPoint","sourceSpatialReference":{"wkid":27700,"latestWkid":27700},"copyrightText":"","parentLayer":null,"subLayers":[],"minScale":2000,"maxScale":1,"defaultVisibility":true,"extent":{"xmin":395008.26,"ymin":226717.29,"xmax":462364.87,"ymax":276355.51,"spatialReference":{"wkid":27700,"latestWkid":27700}},"hasAttachments":false,"htmlPopupType":"esriServerHTMLPopupTypeNone","displayField":"Toid","typeIdField":null,"fields":[{"name":"Toid","type":"esriFieldTypeString","alias":"Toid","length":20,"domain":null},{"name":"OBJECTID","type":"esriFieldTypeOID","alias":"OBJECTID","domain":null},{"name":"SHAPE","type":"esriFieldTypeGeometry","alias":"SHAPE","domain":null},{"name":"TextString","type":"esriFieldTypeString","alias":"TextString","length":250,"domain":null},{"name":"VerDate","type":"esriFieldTypeDate","alias":"VerDate","length":8,"domain":null},{"name":"Height","type":"esriFieldTypeDouble","alias":"Height","domain":null}],"geometryField":{"name":"SHAPE","type":"esriFieldTypeGeometry","alias":"SHAPE"},"canModifyLayer":true,"canScaleSymbols":false,"hasLabels":true,"capabilities":"Map,Query,Data","maxRecordCount":1000,"supportsStatistics":true,"supportsAdvancedQueries":true,"supportedQueryFormats":"JSON, geoJSON","isDataVersioned":false,"ownershipBasedAccessControlForFeatures":{"allowOthersToQuery":true},"useStandardizedQueries":true,"advancedQueryCapabilities":{"useStandardizedQueries":true,"supportsStatistics":true,"supportsHavingClause":true,"supportsCountDistinct":true,"supportsOrderBy":true,"supportsDistinct":true,"supportsPagination":true,"supportsTrueCurve":true,"supportsReturningQueryExtent":true,"supportsQueryWithDistance":true,"supportsSqlExpression":true},"supportsDatumTransformation":true,"dateFieldsTimeReference":null,"supportsCoordinatesQuantization":true}"#

    static func layer(_ id: Int, _ name: String, _ geometry: String) -> String {
        #"{"currentVersion":10.81,"id":\#(id),"name":"\#(name)","type":"Feature Layer","geometryType":"\#(geometry)","sourceSpatialReference":{"wkid":27700,"latestWkid":27700},"extent":{"xmin":393015.77,"ymin":225042.49,"xmax":463270.37,"ymax":277279.44,"spatialReference":{"wkid":27700,"latestWkid":27700}},"fields":[{"name":"OBJECTID","type":"esriFieldTypeOID","alias":"OBJECTID"},{"name":"SHAPE","type":"esriFieldTypeGeometry","alias":"SHAPE"},{"name":"Name","type":"esriFieldTypeString","alias":"Name","length":80}],"capabilities":"Map,Query,Data","maxRecordCount":1000,"supportsStatistics":true,"supportsAdvancedQueries":true,"supportedQueryFormats":"JSON, geoJSON","advancedQueryCapabilities":{"supportsPagination":true,"supportsStatistics":true,"supportsOrderBy":true}}"#
    }

    /// The bulk `layers` body: every layer's definition in one response.
    static let layers = #"{"layers":[\#(layer(0, "Parishes 2015", "esriGeometryPolygon")),\#(layer(1, "UNISDELIVE.UFRM_DCAPPL_POLY", "esriGeometryPolygon")),\#(layer(2, "UNISDELIVE.UFRM_APCASE_POLY", "esriGeometryPolygon")),\#(layer3),\#(layer(4, "Map Areas", "esriGeometryPolygon"))],"tables":[]}"#

    static let directory = #"{"currentVersion":10.91,"folders":["Planning"],"services":[{"name":"Census","type":"MapServer"}]}"#
}

/// Knobs a test turns while the stub is live.
private final class ProxyFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var _mapGone = false
    private var _quirky = false
    /// The proxy no longer fronts the map service: its URL answers with something else.
    var mapGone: Bool {
        get { lock.withLock { _mapGone } }
        set { lock.withLock { _mapGone = newValue } }
    }
    /// The proxy behaves as Stratford-on-Avon's does: every body is the document as a JSON
    /// *string*, and only GET is routed (`405 Allow: GET`).
    var quirky: Bool {
        get { lock.withLock { _quirky } }
        set { lock.withLock { _quirky = newValue } }
    }
}

/// A stub proxy routed by path: the lone MapServer, a proxied directory at `/gis`, a wall
/// that wants a token, an HTML page, and a layer whose parent is not a service.
private func stubProxy(flags: ProxyFlags) -> StubTransport {
    StubTransport { request, _ in
        let path = request.url!.path
        let map = "/EplanningV2/API/v1/Map"
        if flags.quirky {
            guard request.httpMethod == "GET" else { return .json("", status: 405) }
            let plain = try stubProxyBody(path: path, map: map, flags: flags)
            let text = String(decoding: plain.body, as: UTF8.self)
            guard plain.status == 200, text.hasPrefix("{") else { return plain }
            return StubTransport.Reply(status: 200, body: try JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed]))
        }
        return try stubProxyBody(path: path, map: map, flags: flags)
    }
}

private func stubProxyBody(path: String, map: String, flags: ProxyFlags) throws -> StubTransport.Reply {
    switch path {
        case map: return flags.mapGone ? .json(#"{"hello":1}"#) : .json(ProxyFixtures.mapServer)
        case "\(map)/layers": return .json(ProxyFixtures.layers)
        case "\(map)/3": return .json(ProxyFixtures.layer3)
        case "\(map)/3/query": return .json(#"{"count":349114}"#)
        case "/gis": return .json(ProxyFixtures.directory)
        case "/gis/Planning": return .json(#"{"currentVersion":10.91,"folders":[],"services":[]}"#)
        case "/gis/Census/MapServer": return .json(ProxyFixtures.mapServer)
        case "/gis/Census/MapServer/layers": return .json(ProxyFixtures.layers)
        case "/wall", "/wall/3": return .json(#"{"error":{"code":499,"message":"Token Required","details":[]}}"#)
        case "/page": return StubTransport.Reply(body: Data("<html><body>Planning portal</body></html>".utf8))
        case "/orphan/3": return .json(ProxyFixtures.layer3)
        case "/orphan": return .json(#"{"hello":"world"}"#)
        default: return .json("not found", status: 404)
    }
}

final class ProbeTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!
    private var transport: StubTransport!
    private var flags: ProxyFlags!
    private var crawler: Crawler!
    private let map = "https://apps.example.gov.uk/EplanningV2/API/v1/Map"

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        flags = ProxyFlags()
        transport = stubProxy(flags: flags)
        let client = ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 2, baseDelay: 0))
        crawler = Crawler(client: client, database: db)
    }

    override func tearDownWithError() throws {
        crawler = nil; db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func requestPaths() -> [String] { transport.requests.compactMap { $0.url?.path } }

    // MARK: - URLs

    func testBareURLDropsQueryFragmentSlashAndOperation() throws {
        XCTAssertEqual(try ArcGISURL.bareURL("HTTPS://Apps.Example.gov.uk/EplanningV2/API/v1/Map/3/query?where=1%3D1&f=pjson#x").absoluteString,
                       "https://apps.example.gov.uk/EplanningV2/API/v1/Map/3")
        XCTAssertEqual(try ArcGISURL.bareURL("apps.example.gov.uk/api/Map/").absoluteString, "https://apps.example.gov.uk/api/Map")
        XCTAssertEqual(try ArcGISURL.bareURL("https://apps.example.gov.uk/api/Map/layers?f=json").absoluteString, "https://apps.example.gov.uk/api/Map")
        XCTAssertEqual(try ArcGISURL.bareURL("http://gis.internal:6080/api/Map").absoluteString, "http://gis.internal:6080/api/Map")
        XCTAssertThrowsError(try ArcGISURL.bareURL("")) { XCTAssertEqual($0 as? ArcGISURLError, .empty) }
        XCTAssertEqual(ArcGISURL.parent(of: URL(string: "https://apps.example.gov.uk/api/Map/3")!)?.absoluteString, "https://apps.example.gov.uk/api/Map")
        XCTAssertEqual(ArcGISURL.parent(of: URL(string: "https://apps.example.gov.uk/Map")!)?.absoluteString, "https://apps.example.gov.uk")
        XCTAssertNil(ArcGISURL.parent(of: URL(string: "https://apps.example.gov.uk")!))
        XCTAssertEqual(ArcGISURL.lastSegment(of: URL(string: "https://apps.example.gov.uk/api/Map")!), "Map")
    }

    func testResolveAgainstALoneServiceRoot() throws {
        let root = URL(string: map)!
        let server = ServerRecord(id: 1, rootURL: root, friendlyName: "Planning", kind: .service)
        let layer = try XCTUnwrap(try ArcGISURL.resolve("https://apps.example.gov.uk/eplanningv2/api/v1/map/3/query?where=1%3D1", against: [server]))
        XCTAssertEqual(layer.rootURL, root)
        XCTAssertTrue(layer.rootIsService)
        XCTAssertEqual(layer.serviceURL, root)
        XCTAssertEqual(layer.servicePath, "Map")
        XCTAssertNil(layer.folderPath)
        XCTAssertEqual(layer.layerID, 3)
        XCTAssertEqual(layer.layerURL?.absoluteString, map + "/3")
        let service = try XCTUnwrap(try ArcGISURL.resolve(map + "/", against: [server]))
        XCTAssertNil(service.layerID)
        XCTAssertEqual(service.serviceURL, root)
        XCTAssertNil(try ArcGISURL.resolve("https://apps.example.gov.uk/EplanningV2/API/v1/Other/3", against: [server]))
        XCTAssertNil(try ArcGISURL.resolve(map + "/3/extra", against: [server]))
        XCTAssertNil(try ArcGISURL.resolve(map + "/three", against: [server]))
        XCTAssertNil(try ArcGISURL.resolve("https://elsewhere.example/EplanningV2/API/v1/Map/3", against: [server]))
        XCTAssertNil(try ArcGISURL.resolve(map, against: []))
    }

    func testResolveAgainstAProxiedDirectoryRoot() throws {
        let root = URL(string: "https://proxy.example.gov.uk/gis")!
        let server = ServerRecord(id: 2, rootURL: root, friendlyName: "Proxy")
        let loc = try XCTUnwrap(try ArcGISURL.resolve("https://proxy.example.gov.uk/gis/Planning/Census/MapServer/3?f=json", against: [server]))
        XCTAssertEqual(loc, ArcGISLocation(rootURL: root, folderPath: "Planning", servicePath: "Planning/Census",
                                           serviceType: .mapServer, layerID: 3))
        XCTAssertEqual(loc.layerURL?.absoluteString, "https://proxy.example.gov.uk/gis/Planning/Census/MapServer/3")
        let folder = try XCTUnwrap(try ArcGISURL.resolve("https://proxy.example.gov.uk/gis/Planning", against: [server]))
        XCTAssertEqual(folder.folderPath, "Planning")
        XCTAssertEqual(try ArcGISURL.resolve("https://proxy.example.gov.uk/gis?f=json", against: [server]), ArcGISLocation(rootURL: root))
        // The longest root wins: a lone service registered under the proxied directory.
        let lone = ServerRecord(id: 3, rootURL: URL(string: "https://proxy.example.gov.uk/gis/Lone")!, friendlyName: "Lone", kind: .service)
        let picked = try XCTUnwrap(try ArcGISURL.resolve("https://proxy.example.gov.uk/gis/Lone/2", against: [server, lone]))
        XCTAssertTrue(picked.rootIsService)
        XCTAssertEqual(picked.layerID, 2)
        // OGC roots own nothing here.
        let ogc = ServerRecord(id: 4, rootURL: root, friendlyName: "OGC", kind: .ogc)
        XCTAssertNil(try ArcGISURL.resolve("https://proxy.example.gov.uk/gis/X/MapServer", against: [ogc]))
    }

    // MARK: - Classification

    func testClassifyByKeys() {
        func classify(_ text: String) -> ArcGISDocument? { ArcGISProbe.classify(Data(text.utf8)) }
        XCTAssertEqual(classify(ProxyFixtures.mapServer), .service(type: .mapServer, version: 10.81))
        XCTAssertEqual(classify(#"{"currentVersion":"11.2","serviceDescription":"","hasVersionedData":false,"layers":[],"tables":[]}"#),
                       .service(type: .featureServer, version: 11.2))
        XCTAssertEqual(classify(ProxyFixtures.directory), .directory(version: 10.91))
        XCTAssertEqual(classify(#"{"folders":[]}"#), .directory(version: nil))
        XCTAssertEqual(classify(ProxyFixtures.layer3), .layer(id: 3, version: 10.81))
        XCTAssertEqual(classify(#"{"id":7,"name":"Grouped","type":"Group Layer","subLayers":[]}"#), .layer(id: 7, version: nil))
        XCTAssertNil(classify(#"{"count":5}"#))
        XCTAssertNil(classify(#"[1,2]"#))
        XCTAssertNil(classify("<html>"))
        XCTAssertNil(classify(#"{"id":3,"name":"x"}"#), "an id and a name alone could be anything")
        XCTAssertNil(classify(#"{"layers":[{"id":0}]}"#), "layers alone is not a service")
        XCTAssertEqual(ArcGISProbe.describe(Data("<html><body>x</body></html>".utf8)), "an HTML page")
        XCTAssertEqual(ArcGISProbe.describe(Data(#"{"b":1,"a":2}"#.utf8)), "JSON with keys a, b")
    }

    // MARK: - Opening

    func testALayerBehindAProxyOpensAsALoneService() async throws {
        let opened = try await crawler.open(map + "/3?f=pjson")
        XCTAssertTrue(opened.isNewServer)
        XCTAssertEqual(opened.server.kind, .service)
        XCTAssertEqual(opened.server.rootURL.absoluteString, map)
        XCTAssertEqual(opened.server.friendlyName, "apps.example.gov.uk")
        XCTAssertEqual(opened.server.arcgisVersion, 10.81)
        XCTAssertTrue(opened.problems.isEmpty)

        let service = try XCTUnwrap(opened.service)
        XCTAssertEqual(service.name, "Map")
        XCTAssertEqual(service.folderPath, "")
        XCTAssertEqual(service.type, .mapServer)
        XCTAssertEqual(service.url, opened.server.rootURL)
        XCTAssertTrue(service.isCrawled)
        XCTAssertEqual(service.maxRecordCount, 1000)
        XCTAssertNotNil(service.extentWGS84, "the British National Grid extent was reprojected")
        let serviceRows = try await db.services(serverID: opened.server.id)
        XCTAssertEqual(serviceRows.count, 1)
        let folderRows = try await db.folders(serverID: opened.server.id)
        XCTAssertTrue(folderRows.isEmpty)

        let layer = try XCTUnwrap(opened.layer)
        XCTAssertEqual(layer.layerID, 3)
        XCTAssertEqual(layer.name, "Map text")
        XCTAssertTrue(layer.isCrawled)
        XCTAssertEqual(layer.effectiveWkid, 27700)
        XCTAssertEqual(opened.location.layerURL?.absoluteString, map + "/3")
        let all = try await db.layers(serviceID: service.id)
        XCTAssertEqual(all.count, 5)
        XCTAssertTrue(all.allSatisfy(\.isCrawled))
        let raw = try await db.layerRawJSON(id: layer.id)
        XCTAssertTrue(raw?.contains("\"name\":\"Map text\"") == true)

        // The probe asked the layer, then its parent; the crawl read the service and its
        // layers once. Nothing was asked for capabilities.
        XCTAssertEqual(requestPaths(), ["/EplanningV2/API/v1/Map/3", "/EplanningV2/API/v1/Map",
                                        "/EplanningV2/API/v1/Map", "/EplanningV2/API/v1/Map/layers"])
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == "https://apps.example.gov.uk" })
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == "https://apps.example.gov.uk/" })
        XCTAssertTrue(transport.requests.allSatisfy { ($0.url?.query ?? "").contains("f=json") })

        // Queries build on the service URL as on any other.
        let count = try await crawler.probeCount(layerID: layer.id)
        XCTAssertEqual(count, 349114)
        XCTAssertEqual(requestPaths().last, "/EplanningV2/API/v1/Map/3/query")
        let assessed = try await db.layer(id: layer.id)
        XCTAssertEqual(assessed.extractable, true)
    }

    /// Stratford-on-Avon's proxy, both quirks at once: it answers only GET, and every body is
    /// the document wrapped in a JSON string. The probe, the crawl and the count all see through it.
    func testAProxyThatWrapsItsBodiesAndRefusesPostStillOpens() async throws {
        flags.quirky = true
        let opened = try await crawler.open(map + "/3?f=pjson")
        XCTAssertEqual(opened.server.kind, .service)
        XCTAssertEqual(opened.server.arcgisVersion, 10.81)
        let service = try XCTUnwrap(opened.service)
        XCTAssertEqual(service.type, .mapServer)
        XCTAssertEqual(service.maxRecordCount, 1000)
        let layer = try XCTUnwrap(opened.layer)
        XCTAssertEqual(layer.name, "Map text")
        let fields = try await db.fields(layerID: layer.id)
        XCTAssertEqual(fields.map(\.name), ["Toid", "OBJECTID", "SHAPE", "TextString", "VerDate", "Height"])
        let layers = try await db.layers(serviceID: service.id)
        XCTAssertEqual(layers.count, 5)
        XCTAssertTrue(layers.allSatisfy(\.isCrawled))
        // The stored raw JSON is the document, not the wrapper the proxy sent.
        let raw = try await db.layerRawJSON(id: layer.id)
        XCTAssertTrue(raw?.hasPrefix("{") == true, raw ?? "nil")
        // The count is POSTed, refused, and asked again as a GET.
        let count = try await crawler.probeCount(layerID: layer.id)
        XCTAssertEqual(count, 349114)
        XCTAssertEqual(transport.requests.filter { $0.httpMethod == "POST" }.count, 1, "the refusal is learned once")
        XCTAssertEqual(transport.last?.httpMethod, "GET")
    }

    func testHeadersAndCookieReachTheProbe() async throws {
        let opened = try await crawler.open(map + "/3", friendlyName: "Planning",
                                            headerOverrides: (origin: "https://portal.example.gov.uk", referer: "https://portal.example.gov.uk/app/"),
                                            cookie: "AGS_ROLES=\"abc==\"")
        XCTAssertEqual(opened.server.friendlyName, "Planning")
        XCTAssertEqual(opened.server.cookie, "AGS_ROLES=\"abc==\"")
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "AGS_ROLES=\"abc==\"" })
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == "https://portal.example.gov.uk" })
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Referer") == "https://portal.example.gov.uk/app/" })
    }

    func testAKnownLoneServiceOwnsItsURLsWithoutAProbe() async throws {
        let first = try await crawler.open(map + "/3")
        let before = transport.count
        // Any casing, any operation: the registered root owns it, and the service is re-read
        // as a pasted service URL always is — never probed again.
        let again = try await crawler.open("https://apps.example.gov.uk/eplanningv2/api/v1/map/3/query?where=1%3D1")
        XCTAssertFalse(again.isNewServer)
        XCTAssertEqual(again.server.id, first.server.id)
        XCTAssertEqual(again.layer?.layerID, 3)
        XCTAssertTrue(again.location.rootIsService)
        XCTAssertEqual(Array(requestPaths().dropFirst(before)), ["/EplanningV2/API/v1/Map", "/EplanningV2/API/v1/Map/layers"])
        let root = try await crawler.open(map)
        XCTAssertEqual(root.service?.id, again.service?.id)
        XCTAssertNil(root.layer)
        let servers = try await db.servers()
        XCTAssertEqual(servers.count, 1)
    }

    func testAProxiedDirectoryOpensAsAnArcGISRoot() async throws {
        let opened = try await crawler.open("https://proxy.example.gov.uk/gis")
        XCTAssertTrue(opened.isNewServer)
        XCTAssertEqual(opened.server.kind, .arcgis)
        XCTAssertEqual(opened.server.rootURL.absoluteString, "https://proxy.example.gov.uk/gis")
        XCTAssertEqual(opened.server.arcgisVersion, 10.91)
        XCTAssertNil(opened.service)
        let services = try await db.services(serverID: opened.server.id)
        XCTAssertEqual(services.map(\.url.absoluteString), ["https://proxy.example.gov.uk/gis/Census/MapServer"])
        let folders = try await db.folders(serverID: opened.server.id)
        XCTAssertEqual(folders.map(\.path), ["Planning"])
        XCTAssertEqual(requestPaths(), ["/gis", "/gis", "/gis/Planning"])

        // A service URL under it, MapServer segment and all, resolves against the root.
        let before = transport.count
        let layer = try await crawler.open("https://proxy.example.gov.uk/gis/Census/MapServer/3")
        XCTAssertFalse(layer.isNewServer)
        XCTAssertEqual(layer.service?.name, "Census")
        XCTAssertEqual(layer.layer?.layerID, 3)
        XCTAssertNil(layer.location.folderPath)
        XCTAssertEqual(Array(requestPaths().dropFirst(before)), ["/gis/Census/MapServer", "/gis/Census/MapServer/layers"])
    }

    func testAWallIsReportedAsArcGISNotOGC() async throws {
        do {
            _ = try await crawler.open("https://apps.example.gov.uk/wall/3")
            XCTFail("expected the server's refusal")
        } catch ArcGISClientError.tokenRequired(let code, let message, _) {
            XCTAssertEqual(code, 499)
            XCTAssertEqual(message, "Token Required")
        }
        let servers = try await db.servers()
        XCTAssertTrue(servers.isEmpty)
        XCTAssertEqual(requestPaths(), ["/wall/3"], "no capabilities were asked for")
        guard case .refused(let error) = try await crawler.probeArcGIS("https://apps.example.gov.uk/wall") else {
            return XCTFail("expected refused")
        }
        XCTAssertEqual(error, .tokenRequired(code: 499, message: "Token Required", url: URL(string: "https://apps.example.gov.uk/wall")!))
    }

    func testNeitherArcGISNorOGCNamesBothAttempts() async throws {
        do {
            _ = try await crawler.open("https://apps.example.gov.uk/page")
            XCTFail("expected nothing to answer")
        } catch ArcGISProbeError.nothingAnswered(let url, let arcgis, let ogc) {
            XCTAssertEqual(url.absoluteString, "https://apps.example.gov.uk/page")
            XCTAssertTrue(arcgis.contains("an HTML page"), arcgis)
            XCTAssertEqual(ogc.count, 3)
            XCTAssertTrue(String(describing: ArcGISProbeError.nothingAnswered(url: url, arcgis: arcgis, ogc: ogc)).contains("did not answer as ArcGIS"))
        }
        let servers = try await db.servers()
        XCTAssertTrue(servers.isEmpty)
        XCTAssertEqual(requestPaths().count, 4, "one f=json, then WFS, WMS and WMTS")

        do {
            _ = try await crawler.open("https://apps.example.gov.uk/nowhere")
            XCTFail("expected nothing to answer")
        } catch ArcGISProbeError.nothingAnswered(_, let arcgis, _) {
            XCTAssertTrue(arcgis.contains("HTTP 404"), arcgis)
        }

        // A layer whose parent is not a service is not ArcGIS either.
        guard case .notArcGIS(let reason) = try await crawler.probeArcGIS("https://apps.example.gov.uk/orphan/3") else {
            return XCTFail("expected not ArcGIS")
        }
        XCTAssertTrue(reason.contains("is not a service"), reason)
        XCTAssertTrue(reason.contains("hello"), reason)
    }

    func testRefreshRereadsTheLoneServiceAndNoticesWhenItIsGone() async throws {
        let opened = try await crawler.open(map + "/3")
        let before = transport.count
        let problems = try await crawler.shallowCrawl(serverID: opened.server.id)
        XCTAssertTrue(problems.isEmpty)
        XCTAssertEqual(Array(requestPaths().dropFirst(before)), ["/EplanningV2/API/v1/Map", "/EplanningV2/API/v1/Map/layers"])
        let services = try await db.services(serverID: opened.server.id)
        XCTAssertEqual(services.count, 1)
        let layers = try await db.layers(serviceID: opened.service!.id)
        XCTAssertEqual(layers.count, 5)

        flags.mapGone = true
        do {
            try await crawler.shallowCrawl(serverID: opened.server.id)
            XCTFail("expected the root to be reported as no longer a service")
        } catch ArcGISProbeError.notAService(let url, let found) {
            XCTAssertEqual(url.absoluteString, map)
            XCTAssertEqual(found, "JSON with keys hello")
        }
        // Nothing cached was thrown away.
        let kept = try await db.services(serverID: opened.server.id)
        XCTAssertEqual(kept.count, 1)
    }
}
