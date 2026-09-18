import XCTest
import Foundation
import RumenKit

final class ExtractabilityTests: XCTestCase {

    private let root = URL(string: "https://gis.example/arcgis/rest/services")!

    private func service(_ id: Int64, _ name: String, _ type: ServiceType, capabilities: String? = "Map,Query,Data",
                         formats: String? = "JSON, geoJSON, PBF", tileCache: Bool = false) -> ServiceRecord {
        ServiceRecord(id: id, serverID: 1, name: name, type: type,
                      url: root.appendingPathComponent(name).appendingPathComponent(type.name),
                      capabilities: capabilities, maxRecordCount: 1000, supportedQueryFormats: formats,
                      isTileCache: tileCache, fetchedAt: Date())
    }

    private func layer(_ id: Int64, service: Int64, type: String? = "Feature Layer", capabilities: String? = "Map,Query,Data",
                       formats: String? = "JSON, geoJSON, PBF", maxRecordCount: Int? = 2000, paging: Bool? = true,
                       statistics: Bool? = true, oid: String? = "OBJECTID", crawled: Bool = true) -> LayerRecord {
        LayerRecord(id: id, serviceID: service, layerID: 3, name: "L", type: type, objectIdField: oid,
                    maxRecordCount: maxRecordCount, supportedQueryFormats: formats, capabilities: capabilities,
                    supportsPagination: paging, supportsStatistics: statistics, fetchedAt: crawled ? Date() : nil)
    }

    /// A layer with an object ID field gets an OID list, whatever else it supports: asking for
    /// named rows beats asking for a window into a sorted result. Measured against Cornwall's
    /// planning polygons, ids came back in under a second where 2,000 rows by offset took 37.8s.
    func testHappyPathPrefersAnOIDList() {
        let a = Extractability.assess(layer: layer(10, service: 1), service: service(1, "A", .featureServer))
        XCTAssertEqual(a.verdict, true)
        XCTAssertEqual(a.transport, .pbf)
        XCTAssertEqual(a.strategy, .oidList, "even though the layer advertises pagination")
        XCTAssertEqual(a.pageSize, 2000, "the server's own advertised size; the right one is discovered from there")
        XCTAssertFalse(a.viaTwin)
        XCTAssertEqual(a.reason, "PBF, OID list chunking at 2,000 records per request.")
        XCTAssertEqual(a.requestCount(features: 184_212), 93)
        XCTAssertEqual(a.countSentence(features: 184_212), "184,212 features in 93 requests.")
        XCTAssertEqual(a.countSentence(features: 1), "1 feature in 1 request.")
    }

    /// Paging is what a layer with no object ID field falls back to.
    func testOffsetPagingIsTheFallbackWithoutAnObjectID() {
        let a = Extractability.assess(layer: layer(10, service: 1, oid: nil), service: service(1, "A", .featureServer))
        XCTAssertEqual(a.verdict, true)
        XCTAssertEqual(a.strategy, .offset)
        XCTAssertEqual(a.pageSize, 2000, "and it keeps the server's own advertised page size")
        XCTAssertEqual(a.reason, "PBF, offset paging at 2,000 records per request.")
    }

    func testUncrawledIsUnknown() {
        let a = Extractability.assess(layer: layer(10, service: 1, crawled: false), service: service(1, "A", .mapServer))
        XCTAssertNil(a.verdict)
        XCTAssertNil(a.transport)
    }

    func testNonFeatureTypes() {
        let group = Extractability.assess(layer: layer(10, service: 1, type: "Group Layer"), service: service(1, "A", .mapServer))
        XCTAssertEqual(group.verdict, false)
        XCTAssertEqual(group.reason, "This is a group layer; pick one of its sub-layers.")
        let raster = Extractability.assess(layer: layer(10, service: 1, type: "Raster Layer"), service: service(1, "A", .mapServer))
        XCTAssertEqual(raster.verdict, false)
        XCTAssertEqual(raster.reason, "This is a raster layer; nothing to query.")
        let annotation = Extractability.assess(layer: layer(10, service: 1, type: "Annotation Layer"), service: service(1, "A", .mapServer))
        XCTAssertEqual(annotation.reason, "This is an annotation layer; nothing to query.")
        let table = Extractability.assess(layer: layer(10, service: 1, type: "Table"), service: service(1, "A", .mapServer))
        XCTAssertEqual(table.verdict, true, "tables are queryable")
    }

    func testNoQueryCapability() {
        let own = Extractability.assess(layer: layer(10, service: 1, capabilities: "Map,Data"), service: service(1, "A", .mapServer))
        XCTAssertEqual(own.verdict, false)
        XCTAssertEqual(own.reason, "The layer does not advertise the Query capability.")
        let inherited = Extractability.assess(layer: layer(10, service: 1, capabilities: nil),
                                              service: service(1, "A", .mapServer, capabilities: "Map,Tilemap", tileCache: true))
        XCTAssertEqual(inherited.verdict, false)
        XCTAssertEqual(inherited.reason, "The service does not advertise the Query capability. It serves pre-rendered tiles.")
    }

    func testTransportChoice() {
        let json = Extractability.assess(layer: layer(10, service: 1, formats: "JSON, AMF"), service: service(1, "A", .mapServer))
        XCTAssertEqual(json.transport, .json)
        XCTAssertEqual(json.reason, "JSON, OID list chunking at 2,000 records per request.")
        let missing = Extractability.assess(layer: layer(10, service: 1, formats: nil), service: service(1, "A", .mapServer, formats: nil))
        XCTAssertEqual(missing.transport, .json, "no advertised formats means classic JSON")
        let geo = Extractability.assess(layer: layer(10, service: 1, formats: "geoJSON"), service: service(1, "A", .mapServer))
        XCTAssertEqual(geo.verdict, false)
        XCTAssertTrue(geo.reason.contains("only GEOJSON"), geo.reason)
    }

    /// An object ID field wins outright; without one, paging then statistics; without any of
    /// them there is nothing to chunk on.
    func testStrategyLadder() {
        let withOID = Extractability.assess(layer: layer(10, service: 1, paging: false, statistics: true), service: service(1, "A", .mapServer))
        XCTAssertEqual(withOID.strategy, .oidList, "an object ID field beats statistics")
        XCTAssertEqual(withOID.reason, "PBF, OID list chunking at 2,000 records per request.")

        let paging = Extractability.assess(layer: layer(10, service: 1, paging: true, statistics: true, oid: nil), service: service(1, "A", .mapServer))
        XCTAssertEqual(paging.strategy, .offset, "no object ID field: paging next")

        let range = Extractability.assess(layer: layer(10, service: 1, paging: false, statistics: true, oid: nil), service: service(1, "A", .mapServer))
        XCTAssertEqual(range.strategy, .oidRange, "then statistics")
        XCTAssertEqual(range.reason, "PBF, OID range chunking at 2,000 records per request.")

        let noOID = Extractability.assess(layer: layer(10, service: 1, paging: false, statistics: false, oid: nil), service: service(1, "A", .mapServer))
        XCTAssertEqual(noOID.verdict, false)
        XCTAssertTrue(noOID.reason.contains("no object ID field"))

        let fallbackPage = Extractability.assess(layer: layer(10, service: 1, maxRecordCount: nil, oid: nil), service: service(1, "A", .mapServer))
        XCTAssertEqual(fallbackPage.pageSize, 1000, "service maxRecordCount when the layer has none")
    }

    func testTwinIsPreferredWhenBetter() {
        let map = service(1, "A", .mapServer, formats: "JSON")
        let feature = service(2, "A", .featureServer)
        let own = layer(10, service: 1, formats: "JSON", paging: false, statistics: true)
        let twin = layer(20, service: 2)
        let a = Extractability.assess(layer: own, service: map, twin: twin, twinService: feature)
        XCTAssertEqual(a.verdict, true)
        XCTAssertTrue(a.viaTwin)
        XCTAssertEqual(a.sourceLayerID, 20)
        XCTAssertEqual(a.layerID, 10)
        XCTAssertEqual(a.transport, .pbf)
        XCTAssertEqual(a.strategy, .oidList)
        XCTAssertEqual(a.reason, "PBF through the FeatureServer twin, OID list chunking at 2,000 records per request.")
    }

    func testTwinNotUsedWhenOwnIsAsGood() {
        let map = service(1, "A", .mapServer)
        let feature = service(2, "A", .featureServer)
        let a = Extractability.assess(layer: layer(10, service: 1), service: map, twin: layer(20, service: 2), twinService: feature)
        XCTAssertFalse(a.viaTwin)
        XCTAssertEqual(a.sourceLayerID, 10)
    }

    func testTwinRescuesANonExtractableMapServerLayer() {
        let map = service(1, "A", .mapServer, capabilities: "Map")
        let feature = service(2, "A", .featureServer, capabilities: "Query")
        let a = Extractability.assess(layer: layer(10, service: 1, capabilities: nil), service: map,
                                      twin: layer(20, service: 2, capabilities: "Query"), twinService: feature)
        XCTAssertEqual(a.verdict, true)
        XCTAssertTrue(a.viaTwin)
    }

    func testTwinIgnoredWhenItIsNotExtractable() {
        let map = service(1, "A", .mapServer)
        let feature = service(2, "A", .featureServer)
        let a = Extractability.assess(layer: layer(10, service: 1), service: map,
                                      twin: layer(20, service: 2, type: "Raster Layer"), twinService: feature)
        XCTAssertFalse(a.viaTwin)
    }

    // MARK: - Against the fixtures

    func testFixtureLayers() throws {
        let census = try ArcGISJSON.decode(LayerInfo.self, from: Fixtures.data("s6-census-layer3.json"))
        let trailheads = try ArcGISJSON.decode(LayerInfo.self, from: Fixtures.data("hosted-trailheads-layer0.json"))
        func record(_ info: LayerInfo, id: Int64) -> LayerRecord {
            LayerRecord(id: id, serviceID: 1, layerID: info.id, name: info.name, type: info.type,
                        objectIdField: info.oidField, maxRecordCount: info.maxRecordCount,
                        supportedQueryFormats: info.supportedQueryFormats, capabilities: info.capabilities,
                        supportsPagination: info.canPaginate, supportsStatistics: info.canStatistics, fetchedAt: Date())
        }
        let a = Extractability.assess(layer: record(census, id: 1), service: service(1, "Census", .mapServer))
        XCTAssertEqual(a.verdict, true)
        XCTAssertEqual(a.reason, "PBF, OID list chunking at 1,000 records per request.")
        let b = Extractability.assess(layer: record(trailheads, id: 2), service: service(1, "Trailheads", .featureServer))
        XCTAssertEqual(b.reason, "PBF, OID list chunking at 2,000 records per request.")
    }
}
