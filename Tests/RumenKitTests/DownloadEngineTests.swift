import XCTest
import Foundation
import SwiftProtobuf
import RumenKit
import DuckDBKit

/// A stub "Census states" layer with 51 point features and a small page size, served as JSON
/// or PBF, with knobs for the failure modes SPEC §5.6 must survive.
private final class StubLayer: @unchecked Sendable {
    let lock = NSLock()
    var pageSize = 10
    var paging = true
    var statistics = true
    var featureCount = 51
    var failSeqOnce: Set<Int> = []          // resultOffset pages that 503 the first time
    var alwaysFailOffsets: Set<Int> = []    // pages that always 500
    var tokenExpiredAtOffset: Int? = nil     // page that answers 499
    var lieAboutMore = false                 // short page with exceededTransferLimit
    var rejectPBF = false
    var refuseLimitAbove: Int? = nil        // pages asking for more than this get a 500 envelope
    var badRequestAtOffset: Int? = nil      // a page that fails for a reason that is not about size
    var seenFailures: Set<Int> = []
    var requestLog: [String] = []

    func feature(_ oid: Int) -> String {
        #"{"attributes":{"OBJECTID":\#(oid),"STATE_NAME":"State \#(oid)","POP2000":\#(oid * 1000),"WHEN":1782132691000},"geometry":{"x":\#(-120.0 + Double(oid) * 0.5),"y":\#(30.0 + Double(oid) * 0.25)}}"#
    }

    static let fieldsJSON = #"[{"name":"OBJECTID","type":"esriFieldTypeOID"},{"name":"STATE_NAME","type":"esriFieldTypeString","length":25},{"name":"POP2000","type":"esriFieldTypeInteger"},{"name":"WHEN","type":"esriFieldTypeDate"}]"#

    func layerJSON() -> String {
        let advanced = #""advancedQueryCapabilities":{"supportsPagination":\#(paging),"supportsStatistics":\#(statistics),"supportsOrderBy":true},"#
        return #"{"id":3,"name":"states","type":"Feature Layer","geometryType":"esriGeometryPoint","objectIdField":"OBJECTID","hasZ":false,"hasM":false,"maxRecordCount":\#(pageSize),"supportedQueryFormats":"JSON, geoJSON, PBF","capabilities":"Map,Query,Data","supportsStatistics":\#(statistics),\#(advanced)"extent":{"xmin":-120,"ymin":30,"xmax":-94,"ymax":43,"spatialReference":{"wkid":4326}},"fields":\#(Self.fieldsJSON)}"#
    }

    /// Answers a query request from its form body.
    func reply(_ body: String) throws -> StubTransport.Reply {
        lock.withLock { requestLog.append(body) }
        let params = Dictionary(uniqueKeysWithValues: body.split(separator: "&").map { pair -> (String, String) in
            let kv = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            return (kv[0], kv.count > 1 ? kv[1] : "")
        })
        if params["returnCountOnly"] == "true" { return .json(#"{"count":\#(featureCount)}"#) }
        if params["returnIdsOnly"] == "true" {
            return .json(#"{"objectIdFieldName":"OBJECTID","objectIds":[\#((1...featureCount).map(String.init).joined(separator: ","))]}"#)
        }
        if params["outStatistics"] != nil {
            return .json(#"{"fields":[],"features":[{"attributes":{"min_oid":1,"max_oid":\#(featureCount)}}]}"#)
        }
        var ids: [Int]
        var exceeded = false
        if let offset = params["resultOffset"].flatMap(Int.init) {
            let count = params["resultRecordCount"].flatMap(Int.init) ?? pageSize
            if let cap = refuseLimitAbove, count > cap { return .json(#"{"error":{"code":500,"message":"Error performing query operation","details":[]}}"#) }
            let failOnce = lock.withLock { failSeqOnce.contains(offset) && !seenFailures.contains(offset) }
            if failOnce { lock.withLock { _ = seenFailures.insert(offset) }; return .json("busy", status: 503) }
            if alwaysFailOffsets.contains(offset) { return .json("broken", status: 500) }
            if badRequestAtOffset == offset {
                return .json(#"{"error":{"code":400,"message":"Invalid field: NOPE","details":[]}}"#)
            }
            if tokenExpiredAtOffset == offset { return .json(#"{"error":{"code":499,"message":"Token Required","details":[]}}"#) }
            ids = offset < featureCount ? Array((offset + 1)...min(featureCount, offset + count)) : []
            if offset + count < featureCount { exceeded = true }
            if lieAboutMore { ids = Array(ids.prefix(3)); exceeded = true }
        } else if let list = params["objectIds"] {
            ids = list.split(separator: ",").compactMap { Int($0) }
        } else if let whereClause = params["where"], whereClause.contains(">=") {
            let numbers = whereClause.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            ids = Array(numbers[0]...numbers[1]).filter { $0 <= featureCount }
        } else {
            ids = Array(1...min(featureCount, pageSize))
            exceeded = featureCount > pageSize
        }
        if params["f"] == "pbf" {
            if rejectPBF { return .json(#"{"error":{"code":400,"message":"pbf unsupported"}}"#) }
            return StubTransport.Reply(status: 200, body: try pbf(ids: ids, exceeded: exceeded))
        }
        let features = ids.map(feature).joined(separator: ",")
        return .json(#"{"geometryType":"esriGeometryPoint","spatialReference":{"wkid":4326},"fields":\#(Self.fieldsJSON),"features":[\#(features)],"exceededTransferLimit":\#(exceeded)}"#)
    }

    /// The same features as Esri PBF, quantised at 1e-9 with an upper-left origin.
    func pbf(ids: [Int], exceeded: Bool) throws -> Data {
        typealias PB = EsriPBuffer_FeatureCollectionPBuffer
        var result = PB.FeatureResult()
        result.geometryType = .esriGeometryTypePoint
        result.exceededTransferLimit = exceeded
        var sr = PB.SpatialReference(); sr.wkid = 4326; result.spatialReference = sr
        var transform = PB.Transform()
        transform.quantizeOriginPostion = .upperLeft
        var scale = PB.Scale(); scale.xScale = 1e-9; scale.yScale = 1e-9; transform.scale = scale
        var translate = PB.Translate(); translate.xTranslate = -180; translate.yTranslate = 90; transform.translate = translate
        result.transform = transform
        func field(_ name: String, _ type: PB.FieldType) -> PB.Field { var f = PB.Field(); f.name = name; f.fieldType = type; f.alias = name; return f }
        result.fields = [field("OBJECTID", .esriFieldTypeOid), field("STATE_NAME", .esriFieldTypeString),
                         field("POP2000", .esriFieldTypeInteger), field("WHEN", .esriFieldTypeDate)]
        result.features = ids.map { oid in
            var f = PB.Feature()
            var v1 = PB.Value(); v1.sintValue = Int32(oid)
            var v2 = PB.Value(); v2.stringValue = "State \(oid)"
            var v3 = PB.Value(); v3.sintValue = Int32(oid * 1000)
            var v4 = PB.Value(); v4.int64Value = 1_782_132_691_000
            f.attributes = [v1, v2, v3, v4]
            var g = PB.Geometry()
            g.geometryType = .esriGeometryTypePoint
            let x = -120.0 + Double(oid) * 0.5, y = 30.0 + Double(oid) * 0.25
            g.coords = [Int64(((x - translate.xTranslate) / scale.xScale).rounded()), Int64(((translate.yTranslate - y) / scale.yScale).rounded())]
            f.compressedGeometry = .geometry(g)
            return f
        }
        var collection = PB()
        collection.version = "1"
        var query = PB.QueryResult()
        query.results = .featureResult(result)
        collection.queryResult = query
        return try collection.serializedBytes()
    }
}

final class DownloadEngineTests: XCTestCase {

    private var scratch: URL!
    private var db: AppDatabase!
    private var stub: StubLayer!
    private var transport: StubTransport!
    private var engine: DownloadEngine!
    private var layerID: Int64 = 0
    private let root = "https://sampleserver6.arcgisonline.com/arcgis/rest/services"

    override func setUp() async throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        try await db.loadSpatial()
        let stub = StubLayer()
        self.stub = stub
        transport = StubTransport { request, _ in
            let path = request.url!.path
            let s6 = "/arcgis/rest/services"
            switch path {
            case s6: return try .fixture("s6-root.json")
            case "\(s6)/Census/MapServer": return try .fixture("s6-census-mapserver.json")
            case "\(s6)/Census/MapServer/layers": return .json("nope", status: 404)
            case "\(s6)/Census/MapServer/3": return .json(stub.layerJSON())
            case "\(s6)/Census/MapServer/3/query": return try stub.reply(request.encodedParams)
            default:
                if path.hasPrefix("\(s6)/Census/MapServer/") {
                    let id = path.split(separator: "/").last!
                    return .json(#"{"id":\#(id),"name":"Other \#(id)","type":"Feature Layer","geometryType":"esriGeometryPolygon","fields":[{"name":"OBJECTID","type":"esriFieldTypeOID"}]}"#)
                }
                if path.hasPrefix(s6 + "/"), !path.contains("Server") { return .json(#"{"currentVersion":10.91,"folders":[],"services":[]}"#) }
                return .json(#"{"error":{"code":404,"message":"not stubbed: \#(path)"}}"#)
            }
        }
        let client = ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 3, baseDelay: 0))
        let crawler = Crawler(client: client, database: db)
        engine = DownloadEngine(client: client, database: db, crawler: crawler,
                                stagingDirectory: scratch.appendingPathComponent("staging"), concurrency: 3)
        let opened = try await crawler.open(root + "/Census/MapServer/3")
        layerID = try XCTUnwrap(opened.layer).id
    }

    override func tearDownWithError() throws {
        engine = nil; db = nil
        try? FileManager.default.removeItem(at: scratch)
    }

    private func request() -> DownloadRequest {
        DownloadRequest(layerID: layerID, outputDirectory: scratch.appendingPathComponent("out"))
    }

    private func readBack(_ path: String) throws -> (count: Int, valid: Bool, geo: String, columns: [String]) {
        let duck = try DuckDB()
        try duck.run("INSTALL spatial;")
        try duck.run("LOAD spatial;")
        let count = Int(try duck.run("SELECT count(*) FROM read_parquet(?);", [.string(path)]).scalarString ?? "0") ?? 0
        let invalid = try duck.run("SELECT count(*) FROM read_parquet(?) WHERE NOT ST_IsValid(geometry);", [.string(path)]).scalarString
        let geo = try duck.run("SELECT decode(value) FROM parquet_kv_metadata(?) WHERE key::VARCHAR = 'geo';", [.string(path)]).scalarString ?? ""
        let columns = try duck.run("SELECT column_name FROM (DESCRIBE SELECT * FROM read_parquet(?));", [.string(path)]).rows.compactMap { $0.first?.stringValue }
        return (count, invalid == "0", geo, columns)
    }

    // MARK: - Happy path, PBF, offset paging

    func testOffsetPagingDownloadsEverythingViaPBF() async throws {
        let planned = try await engine.start(request())
        XCTAssertEqual(planned.strategy, .offset)
        XCTAssertEqual(planned.transport, .pbf)

        let record = try await engine.wait(downloadID: planned.id)
        // Chunks are handed out as the run goes, not laid out in advance, so the plan is read
        // back once the run has finished rather than the moment it was started.
        let chunks = try await db.chunks(downloadID: planned.id)
        XCTAssertEqual(chunks.count, 6, "51 features in pages of 10")
        XCTAssertEqual(chunks.map(\.offset), [0, 10, 20, 30, 40, 50])
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 51)
        XCTAssertEqual(record.invalidGeometryCount, 0)
        XCTAssertNil(record.stagingPath)
        let path = try XCTUnwrap(record.outputPath)
        XCTAssertTrue(path.hasSuffix("/out/sampleserver6.arcgisonline.com/Census/states.parquet"), path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("staging/download-\(record.id).duckdb").path))

        let back = try readBack(path)
        XCTAssertEqual(back.count, 51)
        XCTAssertTrue(back.valid)
        XCTAssertEqual(back.columns, ["OBJECTID", "STATE_NAME", "POP2000", "WHEN", "geometry"])
        XCTAssertTrue(back.geo.contains(#""encoding":"WKB""#), back.geo)
        XCTAssertTrue(back.geo.contains(#""geometry_types":["Point"]"#), back.geo)
        let geo = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(back.geo.utf8)) as? [String: Any])
        let column = try XCTUnwrap((geo["columns"] as? [String: Any])?["geometry"] as? [String: Any])
        let bbox = try XCTUnwrap(column["bbox"] as? [Double])
        for (actual, expected) in zip(bbox, [-119.5, 30.25, -94.5, 42.75]) { XCTAssertEqual(actual, expected, accuracy: 1e-7) }
        XCTAssertTrue(back.geo.contains(#""name":"WGS 84""#), "PROJJSON crs present: \(back.geo.prefix(300))")
        XCTAssertTrue(stub.requestLog.contains { $0.contains("f=pbf") })
        XCTAssertFalse(stub.requestLog.contains { $0.contains("f=json&objectIds") })

        let duck = try DuckDB()
        try duck.run("INSTALL spatial;")
        try duck.run("LOAD spatial;")
        let first = try duck.run("SELECT \"OBJECTID\", \"STATE_NAME\", \"POP2000\", \"WHEN\"::VARCHAR, ST_X(geometry), ST_Y(geometry) FROM read_parquet(?) ORDER BY 1 LIMIT 1;", [.string(path)]).rows[0]
        XCTAssertEqual(Array(first.prefix(4)), [.int(1), .string("State 1"), .int(1000), .string("2026-06-22 12:51:31")])
        XCTAssertEqual(first[4].doubleValue ?? 0, -119.5, accuracy: 1e-7)
        XCTAssertEqual(first[5].doubleValue ?? 0, 30.25, accuracy: 1e-7, "PBF quantisation is exact to the transform scale, not to the bit")
        let all = try await db.chunks(downloadID: record.id)
        XCTAssertTrue(all.allSatisfy { $0.status == .done })
        XCTAssertEqual(all.map(\.count), [10, 10, 10, 10, 10, 1])
    }

    func testJSONFallbackWhenPBFIsRejected() async throws {
        stub.rejectPBF = true
        let planned = try await engine.start(request())
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(try readBack(try XCTUnwrap(record.outputPath)).count, 51)
    }

    func testRetriesTransientFailures() async throws {
        stub.failSeqOnce = [20, 40]
        let planned = try await engine.start(request())
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 51)
    }

    // MARK: - Failure modes

    func testShortPageClaimingMoreFails() async throws {
        stub.lieAboutMore = true
        let planned = try await engine.start(request())
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.error?.contains("yet said more remain") == true, record.error ?? "")
    }

    func testTokenExpiryPausesTheRun() async throws {
        stub.tokenExpiredAtOffset = 30
        let planned = try await engine.start(request())
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .paused)
        XCTAssertTrue(record.error?.contains("token is required") == true, record.error ?? "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(record.stagingPath)), "staging is kept for resume")
    }

    func testFailedRunResumesWithoutRefetchingDoneChunks() async throws {
        stub.alwaysFailOffsets = [30]
        let planned = try await engine.start(request())
        let failed = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(failed.status, .failed)
        let afterFailure = try await db.chunks(downloadID: planned.id)
        let doneBefore = afterFailure.filter { $0.status == .done }.map(\.seq)
        XCTAssertFalse(doneBefore.isEmpty)
        XCTAssertFalse(doneBefore.contains(3))

        // "Crash" simulation: a new engine over the same database and staging file.
        stub.alwaysFailOffsets = []
        let requestsBefore = stub.requestLog.count
        let client = ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 2, baseDelay: 0))
        let fresh = DownloadEngine(client: client, database: db, crawler: Crawler(client: client, database: db),
                                   stagingDirectory: scratch.appendingPathComponent("staging"), concurrency: 2)
        _ = try await fresh.resume(downloadID: planned.id, outputDirectory: scratch.appendingPathComponent("out"))
        let resumed = try await fresh.wait(downloadID: planned.id)
        XCTAssertEqual(resumed.status, .complete, resumed.error ?? "")
        XCTAssertEqual(resumed.featureCount, 51)
        let fetchedAgain = stub.requestLog[requestsBefore...].filter { $0.contains("resultOffset") }
        XCTAssertEqual(fetchedAgain.count, 6 - doneBefore.count, "only the chunks not already done are fetched")
        XCTAssertEqual(try readBack(try XCTUnwrap(resumed.outputPath)).count, 51, "no duplicates from the retried chunk")
    }

    func testCancelLeavesAResumableRun() async throws {
        stub.pageSize = 1
        let held = HeldGate()
        transport.gate = { request in
            if let offset = request.encodedParams.split(separator: "&").first(where: { $0.hasPrefix("resultOffset=") })
                .flatMap({ Int($0.dropFirst("resultOffset=".count)) }), offset >= 6 {
                try await held.waitUntilOpen()   // Task.sleep inside throws once the run is cancelled
            }
        }
        let planned = try await engine.start(request())
        // Let the first pages land, then cancel while later ones are held open.
        for _ in 0..<200 {
            let done = try await db.chunks(downloadID: planned.id).filter { $0.status == .done }.count
            if done >= 5 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.cancel(downloadID: planned.id)
        let record = try await engine.wait(downloadID: planned.id)
        await held.open()
        XCTAssertEqual(record.status, .cancelled)
        XCTAssertTrue(record.status.isResumable)
    }

    func testRefusesToOverwriteWithoutConsent() async throws {
        var first = request()
        first.overwrite = true
        let one = try await engine.wait(downloadID: try await engine.start(first).id)
        XCTAssertEqual(one.status, .complete)
        let two = try await engine.wait(downloadID: try await engine.start(request()).id)
        XCTAssertEqual(two.status, .failed)
        XCTAssertTrue(two.error?.contains("already exists") == true, two.error ?? "")
        var third = request()
        third.overwrite = true
        let three = try await engine.wait(downloadID: try await engine.start(third).id)
        XCTAssertEqual(three.status, .complete)
    }

    // MARK: - OID strategies

    private func recrawlLayer() async throws {
        let client = ArcGISClient(transport: transport, retry: RetryPolicy(maxAttempts: 2, baseDelay: 0))
        try await Crawler(client: client, database: db).crawlLayer(layerID: layerID)
    }

    func testOIDRangeStrategy() async throws {
        stub.paging = false
        try await recrawlLayer()
        let planned = try await engine.start(request())
        XCTAssertEqual(planned.strategy, .oidRange)
        let record = try await engine.wait(downloadID: planned.id)
        let chunks = try await db.chunks(downloadID: planned.id)
        XCTAssertEqual(chunks.map { ($0.lo ?? 0, $0.hi ?? 0) }.map { "\($0.0)-\($0.1)" }, ["1-10", "11-20", "21-30", "31-40", "41-50", "51-51"])
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(try readBack(try XCTUnwrap(record.outputPath)).count, 51)
        XCTAssertTrue(stub.requestLog.contains { $0.contains("OBJECTID%20%3E%3D%2011%20AND%20OBJECTID%20%3C%3D%2020") }, "range where clauses are sent")
    }

    func testOIDListStrategy() async throws {
        stub.paging = false
        stub.statistics = false
        try await recrawlLayer()
        let planned = try await engine.start(request())
        XCTAssertEqual(planned.strategy, .oidList)
        let record = try await engine.wait(downloadID: planned.id)
        let chunks = try await db.chunks(downloadID: planned.id)
        XCTAssertEqual(chunks.count, 6)
        XCTAssertEqual(chunks[0].objectIDs, Array(1...10))
        XCTAssertEqual(chunks[5].objectIDs, [51])
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(try readBack(try XCTUnwrap(record.outputPath)).count, 51)
    }

    func testDomainLabelsAndWhereClause() async throws {
        // A coded domain on POP2000 (silly, but exercises the CASE) and a where clause that the
        // stub ignores except for passing it through — the count still drives the plan.
        try await db.query("UPDATE field SET domain_json = ? WHERE name = 'POP2000';",
                           [.string(#"{"type":"codedValue","codedValues":[{"code":1000,"name":"One thousand"},{"code":2000,"name":"Two thousand"}]}"#)])
        var r = request()
        r.domainLabels = true
        r.whereClause = "POP2000 > 0"
        let record = try await engine.wait(downloadID: try await engine.start(r).id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        let back = try readBack(try XCTUnwrap(record.outputPath))
        XCTAssertEqual(back.columns, ["OBJECTID", "STATE_NAME", "POP2000", "POP2000_label", "WHEN", "geometry"])
        let duck = try DuckDB()
        let labels = try duck.run("SELECT \"POP2000_label\" FROM read_parquet(?) ORDER BY \"OBJECTID\" LIMIT 3;", [.string(back.count > 0 ? record.outputPath! : "")]).rows
        XCTAssertEqual(labels, [[.string("One thousand")], [.string("Two thousand")], [.null]])
        XCTAssertTrue(stub.requestLog.contains { $0.contains("where=POP2000%20%3E%200") })
    }

    // MARK: - Planner maths

    func testPlannerChunkMaths() {
        XCTAssertEqual(DownloadPlanner.offsetChunks(downloadID: 1, count: 0, pageSize: 10).map(\.offset), [0])
        XCTAssertEqual(DownloadPlanner.offsetChunks(downloadID: 1, count: 10, pageSize: 10).map(\.offset), [0])
        XCTAssertEqual(DownloadPlanner.offsetChunks(downloadID: 1, count: 11, pageSize: 10).map(\.offset), [0, 10])
        XCTAssertEqual(DownloadPlanner.rangeChunks(downloadID: 1, minOID: 5, maxOID: 5, pageSize: 10).map { "\($0.lo!)-\($0.hi!)" }, ["5-5"])
        XCTAssertEqual(DownloadPlanner.rangeChunks(downloadID: 1, minOID: 10, maxOID: 5, pageSize: 10), [])
        let list = DownloadPlanner.listChunks(downloadID: 1, objectIDs: [9, 3, 1, 7, 5], pageSize: 2)
        XCTAssertEqual(list.map(\.objectIDs), [[1, 3], [5, 7], [9]])
        let options = DownloadPlanner.options(for: DownloadChunk(downloadID: 1, seq: 0, kind: .oidRange, lo: 11, hi: 20),
                                              whereClause: "STATE = 'CA'", outWkid: 4326, oidField: "OID", pageSize: 10, canOrderBy: true)
        XCTAssertEqual(options.params["where"], "(STATE = 'CA') AND OID >= 11 AND OID <= 20")
        XCTAssertNil(options.params["orderByFields"], "ranges do not need ordering")
        let paged = DownloadPlanner.options(for: DownloadChunk(downloadID: 1, seq: 2, kind: .offset, offset: 20),
                                            whereClause: "1=1", outWkid: 27700, oidField: "OID", pageSize: 10, canOrderBy: true)
        XCTAssertEqual(paged.params["resultOffset"], "20")
        XCTAssertEqual(paged.params["resultRecordCount"], "10")
        XCTAssertEqual(paged.params["orderByFields"], "OID ASC")
        XCTAssertEqual(paged.params["outSR"], "27700")
    }
}

/// A gate that stays shut until opened; waiting is cancellable through `Task.sleep`.
private actor HeldGate {
    private var isOpen = false
    func open() { isOpen = true }
    func waitUntilOpen() async throws {
        while !isOpen { try await Task.sleep(for: .milliseconds(10)) }
    }
}

extension DownloadEngineTests {
    /// The point of the exercise: a server's advertised `maxRecordCount` is a ceiling, and the
    /// run climbs to it instead of opening there. One request at a time so the climb is exactly
    /// observable rather than dependent on which of three in flight lands first.
    func testThePageSizeClimbsAsTheServerKeepsUp() async throws {
        stub.pageSize = 2_000              // what the server claims it can do
        stub.featureCount = 3_000
        try await recrawlLayer()
        await engine.setConcurrency(1)

        let planned = try await engine.start(request())
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 3_000)

        let chunks = try await db.chunks(downloadID: planned.id)
        XCTAssertEqual(chunks.map(\.limit), [100, 200, 400, 800, 1_500],
                       "doubling from the floor, and the last request asks only for what is left")
        XCTAssertEqual(chunks.map(\.offset), [0, 100, 300, 700, 1_500], "contiguous, no gaps and no overlaps")
    }

    /// Splitting answers "that was too much to ask for" and nothing else. A bad field name is
    /// not about size, and halving the request would only make the server refuse it twice.
    func testAFailureThatIsNotAboutSizeIsNotSplit() async throws {
        stub.badRequestAtOffset = 0
        try await recrawlLayer()
        await engine.setConcurrency(1)

        let planned = try await engine.start(request())
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.error?.contains("Invalid field") == true, record.error ?? "")

        let chunks = try await db.chunks(downloadID: planned.id)
        XCTAssertTrue(chunks.filter { $0.status == .split }.isEmpty, "nothing was halved over a bad field name")
    }

    /// sampleserver6 refused a 1,000-county page after 60 s; the engine must halve and carry on.
    ///
    /// The feed asks for exactly what is left rather than a whole page, so the layer's 51
    /// features go out as one request for 51 — which is why the refusal threshold sits below
    /// that rather than at the old 60.
    func testRefusedChunksAreSplitUntilTheyFit() async throws {
        stub.pageSize = 200
        stub.refuseLimitAbove = 40          // the single request for 51 is refused; its halves fit
        try await recrawlLayer()
        let planned = try await engine.start(request())
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .complete, record.error ?? "")
        XCTAssertEqual(record.featureCount, 51)
        let chunks = try await db.chunks(downloadID: planned.id)
        XCTAssertEqual(chunks.filter { $0.status == .split }.count, 1, "the request for 51 was split once")
        XCTAssertEqual(chunks.filter { $0.status == .done }.compactMap(\.limit).sorted(), [25, 26])
        XCTAssertEqual(chunks.filter { $0.status == .done }.compactMap(\.offset).sorted(), [0, 25])
        XCTAssertTrue(chunks.first?.lastError?.contains("split into 2 and 3") == true, chunks.first?.lastError ?? "")
        XCTAssertEqual(try readBack(try XCTUnwrap(record.outputPath)).count, 51, "no duplicates from the split")
    }

    func testUnsplittableRefusalFailsTheRun() async throws {
        stub.pageSize = 30
        stub.refuseLimitAbove = 10          // 30 → 15 (below the 50 floor: cannot split) → failed
        try await recrawlLayer()
        let planned = try await engine.start(request())
        let record = try await engine.wait(downloadID: planned.id)
        XCTAssertEqual(record.status, .failed)
        XCTAssertTrue(record.error?.contains("Error performing query operation") == true, record.error ?? "")
    }

    func testSplitMaths() {
        let offset = DownloadChunk(downloadID: 1, seq: 0, kind: .offset, offset: 100, limit: 1000)
        let halves = try! XCTUnwrap(DownloadPlanner.split(offset, pageSize: 1000, firstSeq: 7))
        XCTAssertEqual(halves.map { ($0.seq, $0.offset!, $0.limit!) }.map { "\($0.0):\($0.1)+\($0.2)" }, ["7:100+500", "8:600+500"])
        let odd = DownloadChunk(downloadID: 1, seq: 0, kind: .offset, offset: 0, limit: 75)
        XCTAssertEqual(DownloadPlanner.split(odd, pageSize: 75, firstSeq: 1)?.map(\.limit), [37, 38])
        XCTAssertNil(DownloadPlanner.split(DownloadChunk(downloadID: 1, seq: 0, kind: .offset, offset: 0, limit: 49), pageSize: 49, firstSeq: 1))
        let range = DownloadChunk(downloadID: 1, seq: 0, kind: .oidRange, lo: 1, hi: 100, limit: 100)
        XCTAssertEqual(DownloadPlanner.split(range, pageSize: 100, firstSeq: 1)?.map { "\($0.lo!)-\($0.hi!)" }, ["1-50", "51-100"])
        let list = DownloadChunk(downloadID: 1, seq: 0, kind: .oidList, objectIDs: Array(1...60), limit: 60)
        XCTAssertEqual(DownloadPlanner.split(list, pageSize: 60, firstSeq: 1)?.map { $0.objectIDs!.count }, [30, 30])
        XCTAssertNil(DownloadPlanner.split(DownloadChunk(downloadID: 1, seq: 0, kind: .oidList, objectIDs: Array(1...40), limit: 40), pageSize: 40, firstSeq: 1))
    }
}
