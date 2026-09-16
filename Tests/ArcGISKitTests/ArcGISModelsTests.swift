import XCTest
import ArcGISKit

/// Decoding against recorded responses from three real servers: ArcGIS Server 10.9
/// (sampleserver6), a cached basemap (services.arcgisonline.com), and ArcGIS Online hosted.
final class ArcGISModelsTests: XCTestCase {

    func testServiceDirectoryRoot() throws {
        let dir = try ArcGISJSON.decode(ServiceDirectory.self, from: Fixtures.data("s6-root.json"))
        XCTAssertEqual(dir.currentVersion, 10.91)
        XCTAssertEqual(dir.folders.count, 13)
        XCTAssertTrue(dir.folders.contains("Utilities"))
        XCTAssertTrue(dir.services.contains(.init(name: "Census", type: "MapServer")))
        XCTAssertTrue(dir.services.contains(.init(name: "Wildfire", type: "FeatureServer")))
        XCTAssertEqual(dir.services.first { $0.name == "CharlotteLAS" }?.serviceType, .imageServer)
    }

    func testServiceDirectoryFolderListsQualifiedNames() throws {
        let dir = try ArcGISJSON.decode(ServiceDirectory.self, from: Fixtures.data("s6-folder-utilities.json"))
        XCTAssertEqual(dir.folders, [])
        XCTAssertEqual(dir.services.map(\.name), ["Utilities/GeocodingTools", "Utilities/Geometry",
                                                  "Utilities/PrintingTools", "Utilities/RasterUtilities"])
        XCTAssertEqual(dir.services[1].serviceType, .other("GeometryServer"))
    }

    func testMapServerServiceInfo() throws {
        let svc = try ArcGISJSON.decode(ServiceInfo.self, from: Fixtures.data("s6-census-mapserver.json"))
        XCTAssertEqual(svc.mapName, "Layers")
        XCTAssertEqual(svc.capabilitySet, ["Map", "Query", "Data"])
        XCTAssertEqual(svc.supportedQueryFormats, "JSON, geoJSON, PBF")
        XCTAssertEqual(svc.maxRecordCount, 1000)
        XCTAssertFalse(svc.isTileCache)
        XCTAssertEqual(svc.layers.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(svc.layers[3].name, "states")
        XCTAssertEqual(svc.layers[3].type, "Feature Layer")
        XCTAssertEqual(svc.layers[3].geometryType, "esriGeometryPolygon")
        XCTAssertNil(svc.layers[3].parentID, "-1 means no parent")
        XCTAssertEqual(svc.tables, [])
        XCTAssertEqual(svc.spatialReference?.effectiveWkid, 4269)
        XCTAssertEqual(svc.fullExtent?.isEmpty, false)
    }

    func testCachedBasemapIsATileCacheWithoutQuery() throws {
        let svc = try ArcGISJSON.decode(ServiceInfo.self, from: Fixtures.data("agol-world-street-map.json"))
        XCTAssertTrue(svc.isTileCache)
        XCTAssertEqual(svc.singleFusedMapCache, true)
        XCTAssertNotNil(svc.tileInfo?["lods"]?.arrayValue)
        XCTAssertEqual(svc.capabilitySet, ["Map", "Tilemap"])
        XCTAssertFalse(svc.capabilitySet.contains("Query"))
    }

    func testFeatureServerServiceInfo() throws {
        let svc = try ArcGISJSON.decode(ServiceInfo.self, from: Fixtures.data("s6-wildfire-featureserver.json"))
        XCTAssertTrue(svc.capabilitySet.contains("Query"))
        XCTAssertEqual(svc.supportedQueryFormats, "JSON")
        XCTAssertGreaterThan(svc.layers.count, 0)
        XCTAssertNil(svc.mapName)
    }

    func testServerLayerInfo() throws {
        let layer = try ArcGISJSON.decode(LayerInfo.self, from: Fixtures.data("s6-census-layer3.json"))
        XCTAssertEqual(layer.id, 3)
        XCTAssertEqual(layer.name, "states")
        XCTAssertEqual(layer.type, "Feature Layer")
        XCTAssertEqual(layer.geometryType, "esriGeometryPolygon")
        XCTAssertFalse(layer.isTable)
        XCTAssertEqual(layer.maxRecordCount, 1000)
        XCTAssertEqual(layer.queryFormats, ["JSON", "GEOJSON", "PBF"])
        XCTAssertEqual(layer.capabilitySet, ["Map", "Query", "Data"])
        XCTAssertTrue(layer.canPaginate)
        XCTAssertTrue(layer.canStatistics)
        XCTAssertTrue(layer.canOrderBy)
        XCTAssertNil(layer.parentLayer)
        XCTAssertEqual(layer.extent?.isEmpty, false)
        XCTAssertEqual(layer.spatialReference?.effectiveWkid, 4269)
        XCTAssertNil(layer.objectIdField, "Server 10.9 MapServer layers omit the property")
        XCTAssertEqual(layer.oidField, "OBJECTID", "so it is resolved from the OID-typed field")
        XCTAssertGreaterThan(layer.fields.count, 10)
        let oid = try XCTUnwrap(layer.fields.first { $0.type == .oid })
        XCTAssertEqual(oid.name, "OBJECTID")
        XCTAssertEqual(oid.type.duckType, "BIGINT")
        XCTAssertEqual(layer.fields.first { $0.type == .geometry }?.type.duckType, "GEOMETRY")
    }

    func testWildfireLayerBlankGlobalIdIsNil() throws {
        let layer = try ArcGISJSON.decode(LayerInfo.self, from: Fixtures.data("s6-wildfire-layer0.json"))
        XCTAssertEqual(layer.objectIdField, "objectid")
        XCTAssertEqual(layer.oidField, "objectid")
        XCTAssertNil(layer.globalIdField, "\"\" must normalise to nil")
        XCTAssertEqual(layer.hasAttachments, true)
        XCTAssertEqual(layer.hasZ, false)
        XCTAssertTrue(layer.capabilitySet.contains("Query"))
        XCTAssertTrue(layer.capabilitySet.contains("Editing"), "we record it; we never use it")
        XCTAssertEqual(layer.advancedQueryCapabilities?.supportsQueryWithResultType, true)
        XCTAssertEqual(layer.tileMaxRecordCount, 8000)
        XCTAssertTrue(layer.fields.contains { $0.type == .date && $0.type.duckType == "TIMESTAMP" })
        XCTAssertTrue(layer.fields.contains { $0.type == .smallInteger && $0.type.duckType == "SMALLINT" })
    }

    func testHostedLayerInfo() throws {
        let layer = try ArcGISJSON.decode(LayerInfo.self, from: Fixtures.data("hosted-trailheads-layer0.json"))
        XCTAssertEqual(layer.name, "Trailheads")
        XCTAssertEqual(layer.queryFormats, ["JSON", "GEOJSON", "PBF"])
        XCTAssertEqual(layer.capabilitySet, ["Query", "ChangeTracking"])
        XCTAssertEqual(layer.maxRecordCount, 2000)
        XCTAssertEqual(layer.standardMaxRecordCount, 16000)
        XCTAssertEqual(layer.maxRecordCountFactor, 1)
        XCTAssertTrue(layer.canPaginate)
        XCTAssertEqual(layer.advancedQueryCapabilities?.supportsMaxRecordCountFactor, true)
        XCTAssertEqual(layer.supportsCoordinatesQuantization, true)
        XCTAssertEqual(layer.objectIdField, "FID")
        XCTAssertEqual(layer.globalIdField, "GlobalID")
        XCTAssertEqual(layer.spatialReference?.effectiveWkid, 3857, "latestWkid wins over 102100")
        XCTAssertEqual(layer.lastEditDateMillis, 1694533059226)
        XCTAssertEqual(layer.relationships, [])
        let global = try XCTUnwrap(layer.fields.first { $0.name == "GlobalID" })
        XCTAssertEqual(global.type, .globalID)
        XCTAssertEqual(global.type.duckType, "UUID")
        XCTAssertEqual(global.length, 38)
        XCTAssertEqual(global.nullable, false)
        XCTAssertEqual(global.defaultValue, .string("NEWID() WITH VALUES"))
        let name = try XCTUnwrap(layer.fields.first { $0.name == "TRL_NAME" })
        XCTAssertNil(name.domain, "JSON null decodes as absent")
        XCTAssertNil(name.codedValues)
    }

    func testBulkLayersResponse() throws {
        let all = try ArcGISJSON.decode(LayersResponse.self, from: Fixtures.data("s6-census-layers.json"))
        XCTAssertEqual(all.layers.map(\.id), [0, 1, 2, 3])
        XCTAssertEqual(all.tables, [])
        XCTAssertTrue(all.layers.allSatisfy { !$0.fields.isEmpty })
        let single = try ArcGISJSON.decode(LayerInfo.self, from: Fixtures.data("s6-census-layer3.json"))
        XCTAssertEqual(all.layers[3].fields.map(\.name), single.fields.map(\.name),
                       "bulk and per-layer definitions agree")
    }

    func testCountAndErrorEnvelope() throws {
        XCTAssertEqual(try ArcGISJSON.decode(CountResponse.self, from: Fixtures.data("s6-wildfire-count.json")).count, 305)
        let bad = try Fixtures.data("s6-census-layer99.json")
        let envelope = try XCTUnwrap(ArcGISJSON.errorEnvelope(in: bad))
        XCTAssertEqual(envelope.error.code, 500)
        XCTAssertEqual(envelope.error.message, "json")
        XCTAssertNil(ArcGISJSON.errorEnvelope(in: try Fixtures.data("s6-root.json")))
        XCTAssertNil(ArcGISJSON.errorEnvelope(in: try Fixtures.data("s6-wildfire-count.json")))
    }

    func testUnknownFieldTypeDecodesAndMapsToVarchar() throws {
        let json = #"{"id":1,"name":"x","fields":[{"name":"f","type":"esriFieldTypeFuture"}]}"#
        let layer = try ArcGISJSON.decode(LayerInfo.self, from: Data(json.utf8))
        XCTAssertEqual(layer.fields[0].type.rawValue, "esriFieldTypeFuture")
        XCTAssertEqual(layer.fields[0].type.duckType, "VARCHAR")
        XCTAssertNil(EsriFieldType.raster.duckType)
    }

    func testEmptyExtentWithNaNStrings() throws {
        let json = #"{"xmin":"NaN","ymin":"NaN","xmax":"NaN","ymax":"NaN","spatialReference":{"wkid":4326}}"#
        let extent = try ArcGISJSON.decode(Extent.self, from: Data(json.utf8))
        XCTAssertTrue(extent.isEmpty)
        XCTAssertEqual(extent.spatialReference?.wkid, 4326)
    }

    func testCodedValueDomain() throws {
        let json = #"""
        {"id":0,"name":"t","fields":[{"name":"status","type":"esriFieldTypeSmallInteger",
          "domain":{"type":"codedValue","name":"Status","codedValues":[{"name":"Open","code":1},{"name":"Closed","code":2}]}}]}
        """#
        let layer = try ArcGISJSON.decode(LayerInfo.self, from: Data(json.utf8))
        let coded = try XCTUnwrap(layer.fields[0].codedValues)
        XCTAssertEqual(coded.map(\.name), ["Open", "Closed"])
        XCTAssertEqual(coded.map(\.code), [.number(1), .number(2)])
    }

    func testLegacyPaginationFlagIsHonoured() throws {
        let legacy = try ArcGISJSON.decode(LayerInfo.self, from: Data(#"{"id":0,"name":"t","supportsPagination":true}"#.utf8))
        XCTAssertTrue(legacy.canPaginate)
        let none = try ArcGISJSON.decode(LayerInfo.self, from: Data(#"{"id":0,"name":"t"}"#.utf8))
        XCTAssertFalse(none.canPaginate)
        XCTAssertFalse(none.canStatistics)
        let table = try ArcGISJSON.decode(LayerInfo.self, from: Data(#"{"id":5,"name":"t","type":"Table"}"#.utf8))
        XCTAssertTrue(table.isTable)
    }
}
