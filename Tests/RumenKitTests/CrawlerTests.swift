import XCTest
import Foundation
import RumenKit
import SQLiteKit

/// Knobs a test can turn while the stub is live.
private final class StubFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var failing: String?
    /// A root-level folder whose listing answers with a 500 envelope.
    var failingFolder: String? {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }
}

/// A stub "sampleserver6" routed by URL path: recorded fixtures where we have them, minimal
/// synthetic JSON elsewhere, and a few deliberate failures to exercise fallbacks.
private func stubServer(flags: StubFlags = StubFlags()) -> StubTransport {
    StubTransport { request, _ in
        let path = request.url!.path
        let s6 = "/arcgis/rest/services"
        func fixture(_ name: String) throws -> StubTransport.Reply { try .fixture(name) }
        if let folder = flags.failingFolder, path == "\(s6)/\(folder)" {
            return .json(#"{"error":{"code":500,"message":"Folder is on fire","details":[]}}"#)
        }
        switch path {
        case s6: return try fixture("s6-root.json")
        case "\(s6)/Utilities": return try fixture("s6-folder-utilities.json")
        case "\(s6)/Census/MapServer": return try fixture("s6-census-mapserver.json")
        case "\(s6)/Census/MapServer/layers": return try fixture("s6-census-layers.json")
        case "\(s6)/Wildfire/FeatureServer": return try fixture("s6-wildfire-featureserver.json")
        case "\(s6)/Wildfire/FeatureServer/layers": return .json("missing", status: 404)   // forces per-layer fallback
        case "\(s6)/Wildfire/FeatureServer/0": return try fixture("s6-wildfire-layer0.json")
        case "\(s6)/Hurricanes/MapServer":
            return .json(#"{"error":{"code":500,"message":"Service unavailable","details":[]}}"#)
        default:
            if path.hasPrefix("\(s6)/Wildfire/FeatureServer/"), let id = Int(path.split(separator: "/").last!) {
                return .json(#"{"id":\#(id),"name":"Synthetic \#(id)","type":"Feature Layer","geometryType":"esriGeometryPoint","fields":[{"name":"OBJECTID","type":"esriFieldTypeOID"}]}"#)
            }
            if path.hasSuffix("/MapServer") || path.hasSuffix("/FeatureServer") {
                return .json(#"{"currentVersion":10.91,"capabilities":"Map,Query","layers":[],"tables":[]}"#)   // any other service: empty
            }
            if path.hasPrefix(s6 + "/"), !path.contains("Server") {
                return .json(#"{"currentVersion":10.91,"folders":[],"services":[]}"#)   // any other folder: empty
            }
            return .json(#"{"error":{"code":404,"message":"not stubbed: \#(path)"}}"#)
        }
    }
}

final class CrawlerTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!
    private var transport: StubTransport!
    private var flags: StubFlags!
    private var crawler: Crawler!
    private let root = "https://sampleserver6.arcgisonline.com/arcgis/rest/services"

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        flags = StubFlags()
        transport = stubServer(flags: flags)
        let client = ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 2, baseDelay: 0))
        crawler = Crawler(client: client, database: db)
    }

    override func tearDownWithError() throws {
        crawler = nil; db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func requestPaths() -> [String] { transport.requests.compactMap { $0.url?.path } }

    func testOpenRootShallowCrawlsFoldersAndRecordsVersion() async throws {
        let opened = try await crawler.open(root + "/?f=json", friendlyName: "Sample 6")
        XCTAssertTrue(opened.isNewServer)
        XCTAssertNil(opened.service)
        XCTAssertNil(opened.layer)
        XCTAssertEqual(opened.server.friendlyName, "Sample 6")
        XCTAssertEqual(opened.server.arcgisVersion, 10.91)

        let services = try await db.services(serverID: opened.server.id)
        XCTAssertTrue(services.contains { $0.name == "Census" && $0.type == .mapServer })
        XCTAssertTrue(services.contains { $0.name == "Utilities/Geometry" && $0.folderPath == "Utilities" })
        XCTAssertTrue(services.allSatisfy { !$0.isCrawled }, "shallow crawl fetches no service definitions")
        // Root + 13 folders, nothing else.
        XCTAssertEqual(requestPaths().count, 14)
        XCTAssertTrue(requestPaths().allSatisfy { !$0.contains("Server") })
    }

    func testOpenAgainIsFromCache() async throws {
        _ = try await crawler.open(root)
        let before = transport.count
        let again = try await crawler.open(root + "/Utilities")
        XCTAssertFalse(again.isNewServer)
        XCTAssertEqual(again.location.folderPath, "Utilities")
        XCTAssertEqual(transport.count, before, "a known server is not re-listed on open")
    }

    func testOpenLayerURLCrawlsItsServiceViaBulkEndpoint() async throws {
        let opened = try await crawler.open(root + "/Census/MapServer/3/query?where=1%3D1")
        let service = try XCTUnwrap(opened.service)
        XCTAssertEqual(service.name, "Census")
        XCTAssertTrue(service.isCrawled)
        XCTAssertEqual(service.maxRecordCount, 1000)
        let layer = try XCTUnwrap(opened.layer)
        XCTAssertEqual(layer.layerID, 3)
        XCTAssertEqual(layer.name, "states")
        XCTAssertTrue(layer.isCrawled)
        XCTAssertEqual(layer.objectIdField, "OBJECTID")
        let fields = try await db.fields(layerID: layer.id)
        XCTAssertGreaterThan(fields.count, 10)
        let raw = try await db.layerRawJSON(id: layer.id)
        XCTAssertTrue(raw?.contains("\"name\":\"states\"") == true, "raw is the single layer element")
        XCTAssertFalse(raw?.contains("\"layers\":[") == true)

        let paths = requestPaths()
        XCTAssertTrue(paths.contains("/arcgis/rest/services/Census/MapServer"))
        XCTAssertTrue(paths.contains("/arcgis/rest/services/Census/MapServer/layers"))
        XCTAssertFalse(paths.contains("/arcgis/rest/services/Census/MapServer/3"), "bulk covered it")
        let allLayers = try await db.layers(serviceID: service.id)
        XCTAssertTrue(allLayers.allSatisfy(\.isCrawled))
    }

    func testBulkFailureFallsBackToPerLayerRequests() async throws {
        let opened = try await crawler.open(root + "/Wildfire/FeatureServer/0")
        let layer = try XCTUnwrap(opened.layer)
        XCTAssertEqual(layer.objectIdField, "objectid")
        XCTAssertEqual(layer.hasAttachments, true)
        let service = try XCTUnwrap(opened.service)
        let all = try await db.layers(serviceID: service.id)
        XCTAssertGreaterThan(all.count, 1)
        XCTAssertTrue(all.allSatisfy(\.isCrawled))
        XCTAssertTrue(all.contains { $0.name.hasPrefix("Synthetic") })
        let paths = requestPaths()
        XCTAssertTrue(paths.contains("/arcgis/rest/services/Wildfire/FeatureServer/layers"))
        XCTAssertTrue(paths.contains("/arcgis/rest/services/Wildfire/FeatureServer/0"))
    }

    func testEveryRequestCarriesTheHeaders() async throws {
        _ = try await crawler.open(root + "/Census/MapServer")
        for request in transport.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://sampleserver6.arcgisonline.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://sampleserver6.arcgisonline.com/")
        }
    }

    /// A URL outside the ArcGIS shape is asked what it is (decision 19), then taken for an OGC
    /// endpoint (M10): the three capabilities are asked for, and when none answers the error
    /// names every attempt, the ArcGIS one included, and nothing is kept.
    func testNonArcGISURLIsProbedForOGCServicesAndForgottenWhenNoneAnswer() async throws {
        await XCTAssertThrowsErrorAsync(try await self.crawler.open("https://example.com/nothing")) { error in
            guard case ArcGISProbeError.nothingAnswered(let url, let arcgis, let attempts) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(url.absoluteString, "https://example.com/nothing")
            XCTAssertTrue(arcgis.contains("ArcGIS error 404"), arcgis)
            XCTAssertEqual(attempts.count, 3)
        }
        XCTAssertEqual(transport.count, 4, "one f=json, then the three capabilities")
        let servers = try await db.servers()
        XCTAssertTrue(servers.isEmpty)
        XCTAssertThrowsError(try ArcGISURL.parse("https://example.com/nothing")) { error in
            XCTAssertEqual(error as? ArcGISURLError, .notArcGIS("https://example.com/nothing"))
        }
    }

    func testDeepCrawlContinuesPastBrokenServicesAndReportsThem() async throws {
        let opened = try await crawler.open(root)
        let log = EventLog()
        let failures = try await crawler.deepCrawl(serverID: opened.server.id) { event in
            log.append(event)
        }
        XCTAssertEqual(failures.count, 1)
        guard case .failed(let what, let message) = failures[0] else { return XCTFail("expected .failed") }
        XCTAssertEqual(what, "Hurricanes")
        XCTAssertTrue(message.contains("Service unavailable"), message)

        let server = try await db.server(id: opened.server.id)
        XCTAssertNotNil(server.lastDeepCrawlAt)
        let services = try await db.services(serverID: server.id)
        let census = try XCTUnwrap(services.first { $0.name == "Census" })
        XCTAssertTrue(census.isCrawled)
        let events = log.events
        XCTAssertTrue(events.contains(.service(name: "Census", layers: 4)))
        XCTAssertTrue(events.contains(.layer(name: "states")))
        XCTAssertTrue(events.contains(.directory(folderPath: "Utilities", services: 4)))
    }

    func testRawElementSlicing() throws {
        let bulk = try Fixtures.data("s6-census-layers.json")
        let element = try XCTUnwrap(try Crawler.rawElement(for: 3, in: bulk))
        let decoded = try ArcGISJSON.decode(LayerInfo.self, from: element)
        XCTAssertEqual(decoded.name, "states")
        XCTAssertNil(try Crawler.rawElement(for: 99, in: bulk))
    }
}

/// Collects crawl events from the progress callback, which may run off the test's task.
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [CrawlEvent]()
    func append(_ e: CrawlEvent) { lock.withLock { storage.append(e) } }
    var events: [CrawlEvent] { lock.withLock { storage } }
}

extension CrawlerTests {
    func testDeepCrawlSkipsFreshServicesSoItResumes() async throws {
        let opened = try await crawler.open(root)
        _ = try await crawler.deepCrawl(serverID: opened.server.id)
        let after = transport.count
        _ = try await crawler.deepCrawl(serverID: opened.server.id)
        let second = transport.count - after
        XCTAssertEqual(second, 15, "the directory re-listing (root + 13 folders) plus one retry of the service that failed; nothing crawled successfully is fetched again")
        _ = try await crawler.deepCrawl(serverID: opened.server.id, skipFresh: 0)
        XCTAssertGreaterThan(transport.count - after - second, 14, "with no freshness window everything is re-crawled")
    }
}

// MARK: - Folder listings (M8)

extension CrawlerTests {
    /// A folder the shallow crawl cannot read still has a row: its error is recorded, the tree
    /// shows it, and listing it again clears the error.
    func testFolderThatFailsToListIsRecordedAndRetried() async throws {
        flags.failingFolder = "Elevation"
        let opened = try await crawler.open(root)
        XCTAssertEqual(opened.problems.map(\.folderPath), ["Elevation"])
        XCTAssertTrue(opened.problems[0].message.contains("Folder is on fire"), opened.problems[0].message)

        let folders = try await db.folders(serverID: opened.server.id)
        XCTAssertEqual(folders.count, 13, "every folder the root lists has a row")
        let elevation = try XCTUnwrap(folders.first { $0.path == "Elevation" })
        XCTAssertNil(elevation.fetchedAt)
        XCTAssertEqual(elevation.parentPath, "")
        XCTAssertEqual(elevation.name, "Elevation")
        XCTAssertTrue(elevation.lastError?.contains("Folder is on fire") == true, elevation.lastError ?? "")
        let utilities = try XCTUnwrap(folders.first { $0.path == "Utilities" })
        XCTAssertTrue(utilities.isListed)
        XCTAssertNil(utilities.lastError)
        let failed = try await db.failedFolders(serverID: opened.server.id)
        XCTAssertEqual(failed.map(\.path), ["Elevation"])

        let services = try await db.services(serverID: opened.server.id)
        let tree = TreeBuilder.build(server: opened.server, services: services, layersByService: [:], folders: folders)
        let node = try XCTUnwrap(tree.find(.folder(serverID: opened.server.id, path: "Elevation")))
        XCTAssertEqual(node.lastError, elevation.lastError)
        XCTAssertEqual(node.children, [])
        XCTAssertEqual(TreeBuilder.failedFolders(in: tree).map(\.name), ["Elevation"])
        XCTAssertNotNil(tree.find(.folder(serverID: opened.server.id, path: "Utilities"))?.fetchedAt)

        // Retry: the server recovers, the folder page's Retry lists it again.
        flags.failingFolder = nil
        try await crawler.crawlFolder(serverID: opened.server.id, path: "Elevation")
        let after = try await db.folders(serverID: opened.server.id)
        let recovered = try XCTUnwrap(after.first { $0.path == "Elevation" })
        XCTAssertNil(recovered.lastError)
        XCTAssertNotNil(recovered.fetchedAt)
        let none = try await db.failedFolders(serverID: opened.server.id)
        XCTAssertEqual(none.count, 0)

        // And a retry that fails again writes the new message.
        flags.failingFolder = "Elevation"
        await XCTAssertThrowsErrorAsync(try await self.crawler.crawlFolder(serverID: opened.server.id, path: "Elevation"))
        let again = try await db.failedFolders(serverID: opened.server.id)
        XCTAssertEqual(again.map(\.path), ["Elevation"])
        XCTAssertNotNil(again.first?.fetchedAt, "the earlier successful listing's time is kept")
    }

    /// A folder that vanishes from its parent's listing goes, with its sub-folders and services.
    func testPrunedFoldersTakeTheirServicesWithThem() async throws {
        let server = try await db.addServer(rootURL: URL(string: root)!, friendlyName: "s6")
        try await db.upsertFolders(serverID: server.id, parentPath: "", paths: ["A", "B"])
        try await db.upsertFolders(serverID: server.id, parentPath: "A", paths: ["A/C"])
        try await db.upsertServices(serverID: server.id, rootURL: URL(string: root)!, folderPath: "A/C",
                                    entries: [ServiceDirectory.Entry(name: "A/C/Deep", type: "MapServer")])
        try await db.upsertServices(serverID: server.id, rootURL: URL(string: root)!, folderPath: "B",
                                    entries: [ServiceDirectory.Entry(name: "B/Kept", type: "MapServer")])
        try await db.pruneFolders(serverID: server.id, parentPath: "", keeping: ["B"])
        let folders = try await db.folders(serverID: server.id)
        XCTAssertEqual(folders.map(\.path), ["B"])
        let services = try await db.services(serverID: server.id)
        XCTAssertEqual(services.map(\.name), ["B/Kept"])
        try await db.forgetServer(id: server.id)
        let gone = try await db.folders(serverID: server.id)
        XCTAssertEqual(gone.count, 0)
    }
}

// MARK: - Deep crawl parallelism

extension CrawlerTests {
    /// Services are crawled several at a time, bounded by the crawl's width and the client's
    /// per-host cap, and the result is the same set of crawled services and failures.
    func testDeepCrawlRunsServicesInParallel() async throws {
        let opened = try await crawler.open(root)
        transport.delay = .milliseconds(15)
        let failures = try await crawler.deepCrawl(serverID: opened.server.id, concurrency: 4)
        XCTAssertEqual(failures.count, 1)
        XCTAssertGreaterThan(transport.maxConcurrent, 1, "service crawls overlap")
        XCTAssertLessThanOrEqual(transport.maxConcurrent, 4, "never beyond the client's per-host cap")
        let services = try await db.services(serverID: opened.server.id)
        let crawled = services.filter { $0.type.hasLayers && $0.name != "Hurricanes" }
        XCTAssertTrue(crawled.allSatisfy(\.isCrawled), "every service that can be crawled was")
    }
}
