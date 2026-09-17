import XCTest
import Foundation
import ArcGISKit
import DuckDBKit

/// M7: every format round-trips a staged page's count and geometry when read back with
/// DuckDB; a stored GeoParquet re-exports without a network; the Stored tab's file view
/// renders a grid.
final class ExporterTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Three British National Grid points (London, Edinburgh, Cardiff) with a GUID, a date, and a
    /// coded-value domain on POP, staged as a download would stage them.
    private func makeStaging(name: String = "staging") throws -> StagingDatabase {
        let fields = [
            FieldRecord(id: 1, layerID: 1, position: 0, name: "OBJECTID", esriType: .oid, duckType: "BIGINT"),
            FieldRecord(id: 2, layerID: 1, position: 1, name: "NAME", esriType: .string, duckType: "VARCHAR", length: 40),
            FieldRecord(id: 3, layerID: 1, position: 2, name: "POP", esriType: .integer, duckType: "INTEGER",
                        domainJSON: #"{"type":"codedValue","codedValues":[{"code":1,"name":"Small"},{"code":2,"name":"Large"}]}"#),
            FieldRecord(id: 4, layerID: 1, position: 3, name: "WHEN", esriType: .date, duckType: "TIMESTAMP"),
            FieldRecord(id: 5, layerID: 1, position: 4, name: "GID", esriType: .globalID, duckType: "UUID"),
            FieldRecord(id: 6, layerID: 1, position: 5, name: "Shape", esriType: .geometry, duckType: "GEOMETRY"),
        ]
        let staging = try StagingDatabase(path: scratch.appendingPathComponent("\(name).duckdb").path, fields: fields,
                                          oidField: "OBJECTID", hasZ: false, hasM: false)
        let set = try ArcGISJSON.decode(FeatureSet.self, from: Data("""
            {"geometryType":"esriGeometryPoint","spatialReference":{"wkid":27700},
             "fields":[{"name":"OBJECTID","type":"esriFieldTypeOID"},{"name":"NAME","type":"esriFieldTypeString"},
                       {"name":"POP","type":"esriFieldTypeInteger"},{"name":"WHEN","type":"esriFieldTypeDate"},
                       {"name":"GID","type":"esriFieldTypeGlobalID"}],
             "features":[
               {"attributes":{"OBJECTID":3,"NAME":"Cardiff","POP":1,"WHEN":1782132691000,"GID":"{6B29FC40-CA47-1067-B31D-00DD010662DA}"},"geometry":{"x":318000,"y":176000}},
               {"attributes":{"OBJECTID":1,"NAME":"London","POP":2,"WHEN":1782132691000,"GID":"{6B29FC40-CA47-1067-B31D-00DD010662DB}"},"geometry":{"x":530000,"y":180000}},
               {"attributes":{"OBJECTID":2,"NAME":"Edinburgh","POP":2,"WHEN":null,"GID":null},"geometry":{"x":326000,"y":674000}}
             ]}
            """.utf8))
        try staging.append(FeaturePage(json: set, hasZ: false, hasM: false), chunk: 0)
        return staging
    }

    private func spatialEngine() throws -> DuckDB {
        let duck = try DuckDB()
        try duck.run("INSTALL spatial;")
        try duck.run("LOAD spatial;")
        return duck
    }

    // MARK: - Every format from staging

    func testGeoParquetFromStaging() throws {
        let staging = try makeStaging()
        let out = scratch.appendingPathComponent("out/a.parquet")
        let result = try Exporter.export(staging, to: out, format: .geoParquet, outWkid: 27700, domainLabels: true, overwrite: false)
        XCTAssertEqual(result.featureCount, 3)
        XCTAssertEqual(result.invalidGeometries, 0)
        let duck = try spatialEngine()
        let rows = try duck.run("SELECT \"OBJECTID\", \"NAME\", \"POP_label\", \"GID\"::VARCHAR, ST_X(geometry) FROM read_parquet(?) ORDER BY 1;", [.string(out.path)]).rows
        XCTAssertEqual(rows.map { $0[1] }, [.string("London"), .string("Edinburgh"), .string("Cardiff")], "ordered by OID")
        XCTAssertEqual(rows[0][2], .string("Large"))
        XCTAssertEqual(rows[0][3], .string("6b29fc40-ca47-1067-b31d-00dd010662db"), "GUID braces stripped, typed UUID")
        XCTAssertEqual(rows[1][3], .null)
        XCTAssertEqual(rows[0][4].doubleValue ?? 0, 530_000, accuracy: 0.001)
        let geo = try duck.run("SELECT decode(value) FROM parquet_kv_metadata(?) WHERE key::VARCHAR = 'geo';", [.string(out.path)]).scalarString ?? ""
        XCTAssertTrue(geo.contains("\"OSGB36 / British National Grid\"") || geo.contains("27700"), geo.prefix(200).description)
    }

    func testGeoJSONFromStagingIsWGS84() throws {
        let staging = try makeStaging()
        let out = scratch.appendingPathComponent("out/a.geojson")
        let result = try Exporter.export(staging, to: out, format: .geoJSON, outWkid: 27700, domainLabels: false, overwrite: false)
        XCTAssertEqual(result.featureCount, 3)
        XCTAssertGreaterThan(result.bytes, 0)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.contains("\"FeatureCollection\""), text.prefix(120).description)
        XCTAssertTrue(text.contains("\"GID\": \"6B29FC40-CA47-1067-B31D-00DD010662DB\""), "GUID written as plain text: \(text.prefix(400))")
        let duck = try spatialEngine()
        let rows = try duck.run("SELECT \"NAME\", ST_X(geom), ST_Y(geom) FROM ST_Read(?) ORDER BY \"OBJECTID\";", [.string(out.path)]).rows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0][0], .string("London"))
        XCTAssertEqual(rows[0][1].doubleValue ?? 0, -0.1276, accuracy: 0.01, "longitude first: the axis order is honoured")
        XCTAssertEqual(rows[0][2].doubleValue ?? 0, 51.5074, accuracy: 0.01)
        XCTAssertEqual(rows[1][2].doubleValue ?? 0, 55.95, accuracy: 0.02, "Edinburgh")
    }

    func testCSVFromStagingCarriesWKT() throws {
        let staging = try makeStaging()
        let out = scratch.appendingPathComponent("out/a.csv")
        let result = try Exporter.export(staging, to: out, format: .csv, outWkid: 27700, domainLabels: true, overwrite: false)
        XCTAssertEqual(result.featureCount, 3)
        let text = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("OBJECTID,NAME,POP,POP_label,WHEN,GID,geometry\n"), text.prefix(80).description)
        XCTAssertTrue(text.contains("POINT (530000 180000)"), "WKT in the native spatial reference")
        let duck = try spatialEngine()
        let rows = try duck.run("""
            SELECT "NAME", ST_GeometryType(ST_GeomFromText(geometry))::VARCHAR, "WHEN"::VARCHAR
            FROM read_csv(?) ORDER BY "OBJECTID";
            """, [.string(out.path)]).rows
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0][1], .string("POINT"))
        XCTAssertEqual(rows[0][2], .string("2026-06-22 12:51:31"))
    }

    func testRefusesToOverwriteWithoutConsent() throws {
        let staging = try makeStaging()
        let out = scratch.appendingPathComponent("out/a.csv")
        _ = try Exporter.export(staging, to: out, format: .csv, outWkid: 27700, domainLabels: false, overwrite: false)
        XCTAssertThrowsError(try Exporter.export(staging, to: out, format: .csv, outWkid: 27700, domainLabels: false, overwrite: false)) { error in
            XCTAssertEqual(error as? ExportError, .outputExists(out.path))
        }
        XCTAssertNoThrow(try Exporter.export(staging, to: out, format: .csv, outWkid: 27700, domainLabels: false, overwrite: true))
    }

    // MARK: - Re-export from a stored GeoParquet

    func testReexportFromParquetWithoutTheServer() throws {
        let staging = try makeStaging()
        let parquet = scratch.appendingPathComponent("out/Server/Service/layer.parquet")
        _ = try Exporter.export(staging, to: parquet, format: .geoParquet, outWkid: 27700, domainLabels: false, overwrite: false)

        let geojson = Exporter.siblingPath(of: parquet, format: .geoJSON)
        XCTAssertEqual(geojson.lastPathComponent, "layer.geojson")
        let a = try Exporter.reexport(parquet: parquet, sourceWkid: 27700, to: geojson, format: .geoJSON, overwrite: false)
        XCTAssertEqual(a.featureCount, 3)
        XCTAssertEqual(a.invalidGeometries, 0)
        let duck = try spatialEngine()
        let rows = try duck.run("SELECT \"NAME\", ST_Y(geom), \"GID\" FROM ST_Read(?) ORDER BY \"OBJECTID\";", [.string(geojson.path)]).rows
        XCTAssertEqual(rows[0][0], .string("London"))
        XCTAssertEqual(rows[0][1].doubleValue ?? 0, 51.5074, accuracy: 0.01, "reprojected from British National Grid")
        XCTAssertEqual(rows[0][2], .string("6b29fc40-ca47-1067-b31d-00dd010662db"), "UUID column written as text")

        let csv = Exporter.siblingPath(of: parquet, format: .csv)
        let b = try Exporter.reexport(parquet: parquet, sourceWkid: 27700, to: csv, format: .csv, overwrite: false)
        XCTAssertEqual(b.featureCount, 3)
        let text = try String(contentsOf: csv, encoding: .utf8)
        XCTAssertTrue(text.contains("POINT (530000 180000)"), "CSV keeps the file's own spatial reference")

        XCTAssertThrowsError(try Exporter.reexport(parquet: parquet, sourceWkid: 27700, to: csv, format: .csv, overwrite: false)) { error in
            XCTAssertEqual(error as? ExportError, .outputExists(csv.path))
        }
        XCTAssertThrowsError(try Exporter.reexport(parquet: parquet, sourceWkid: 27700, to: parquet, format: .geoParquet, overwrite: true)) { error in
            XCTAssertEqual(error as? ExportError, .unsupportedFormat(.geoParquet))
        }
        let missing = scratch.appendingPathComponent("nope.parquet")
        XCTAssertThrowsError(try Exporter.reexport(parquet: missing, sourceWkid: 4326, to: csv, format: .csv, overwrite: true)) { error in
            XCTAssertEqual(error as? ExportError, .missingSource(missing.path))
        }
    }

    // MARK: - Export records

    func testExportRecordsFollowTheirDownload() async throws {
        let db = try AppDatabase(path: scratch.appendingPathComponent("explorer.sqlite").path)
        try await db.migrate()
        let download = try await db.createDownload(layerID: 7, transport: .pbf, strategy: .offset, whereClause: "1=1",
                                                   outWkid: 27700, format: .geoParquet, domainLabels: false)
        let result = ExportResult(path: "/tmp/x/layer.geojson", sha256: "ab", bytes: 10, featureCount: 3, invalidGeometries: 0)
        let first = try await db.recordExport(downloadID: download.id, format: .geoJSON, outWkid: 4326, result: result)
        XCTAssertEqual(first.format, .geoJSON)
        let again = try await db.recordExport(downloadID: download.id, format: .geoJSON, outWkid: 4326, result: result)
        XCTAssertNotEqual(again.id, first.id)
        let byLayer = try await db.exports(layerID: 7)
        XCTAssertEqual(byLayer.map(\.id), [again.id], "a re-export of the same path replaces its record")
        let byDownload = try await db.exports(downloadID: download.id)
        XCTAssertEqual(byDownload.count, 1)
        let otherLayer = try await db.exports(layerID: 8)
        XCTAssertEqual(otherLayer.count, 0)
        try await db.deleteDownload(id: download.id)
        let afterDelete = try await db.exports(layerID: 7)
        XCTAssertEqual(afterDelete.count, 0, "exports go with their download")
    }

    // MARK: - Stored file view

    func testStoredFileSummaryAndQueries() async throws {
        let staging = try makeStaging()
        let parquet = scratch.appendingPathComponent("out/layer.parquet")
        _ = try Exporter.export(staging, to: parquet, format: .geoParquet, outWkid: 27700, domainLabels: false, overwrite: false)
        let file = try StoredFile(path: parquet.path)
        let summary = try await file.summary()
        XCTAssertEqual(summary.rows, 3)
        XCTAssertGreaterThan(summary.bytes, 0)
        XCTAssertEqual(summary.columns.map(\.name), ["OBJECTID", "NAME", "POP", "WHEN", "GID", "geometry"])
        XCTAssertEqual(summary.columns.last?.type, "GEOMETRY('EPSG:27700')", "the file's CRS rides on the type")

        let page = try await file.query(StoredFile.defaultSQL)
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.grid.columns.map(\.name), ["OBJECTID", "NAME", "POP", "WHEN", "GID", "geometry"])
        XCTAssertEqual(page.grid.columns.map(\.typeLabel), ["BIGINT", "VARCHAR", "INTEGER", "TIMESTAMP", "UUID", "GEOMETRY('EPSG:27700')"])
        XCTAssertTrue(page.grid.columns[0].isNumeric)
        XCTAssertFalse(page.grid.columns[1].isNumeric)
        XCTAssertEqual(page.grid.rows[0], ["1", "London", "2", "2026-06-22 12:51:31", "6b29fc40-ca47-1067-b31d-00dd010662db", "POINT (530000 180000)"])
        XCTAssertEqual(page.grid.rows[1][3], "NULL")

        let short = try await file.query("SELECT \"NAME\", ST_Buffer(geometry, 10) AS g FROM data ORDER BY 1;", limit: 2)
        XCTAssertTrue(short.truncated)
        XCTAssertEqual(short.total, 3)
        XCTAssertEqual(short.grid.rows.count, 2)
        XCTAssertTrue(short.grid.rows[0][1].hasPrefix("POLYGON, "), short.grid.rows[0][1])
        XCTAssertTrue(short.grid.rows[0][1].hasSuffix(" vertices"), short.grid.rows[0][1])

        let listed = try await file.query("SELECT [1, 2] AS l, {'a': 1} AS s FROM data LIMIT 1")
        XCTAssertEqual(listed.grid.rows[0], ["[1, 2]", "{'a': 1}"], "nested types are shown as text")

        await XCTAssertThrowsErrorAsync(try await file.query("SELECT nope FROM data")) { error in
            XCTAssertTrue(String(describing: error).contains("nope"), String(describing: error))
        }
        XCTAssertThrowsError(try StoredFile(path: scratch.appendingPathComponent("missing.parquet").path))
    }
}
