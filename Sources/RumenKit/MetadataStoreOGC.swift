import Foundation
import SQLiteKit

// Persistence for OGC services and layers (M10). They live in the same `service` and `layer`
// tables as ArcGIS ones, so the tree, the transfers and the column search see one world; the
// OGC-only detail rides in `ogc_json`, and a layer is identified across crawls by `ogc_name`
// rather than by its position in the document.
extension AppDatabase {

    /// Records an OGC service (one per type at the endpoint) with its parsed detail. The row's
    /// URL is the root with `service=<type>`, unique per type.
    @discardableResult
    public func upsertOGCService(serverID: Int64, rootURL: URL, document: OGCCapabilitiesDocument,
                                 fetchedAt: Date = Date()) throws -> ServiceRecord {
        let type = document.type
        let url = OGCURL.url(root: rootURL, params: ["service": type.name])
        let detail = document.detail
        let json = try String(decoding: JSONEncoder().encode(detail), as: UTF8.self)
        let name = detail.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? detail.title! : type.name
        let extent = BoundingBox.union(of: document.layers.compactMap(\.bboxWGS84))
        let id = try query("""
            INSERT INTO service (server_id, folder_path, name, type, url, capabilities, max_record_count,
                supported_query_formats, extent_wgs84_json, ogc_json, fetched_at)
            VALUES (?, '', ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT (server_id, url) DO UPDATE SET
                name = excluded.name, type = excluded.type, capabilities = excluded.capabilities,
                max_record_count = excluded.max_record_count, supported_query_formats = excluded.supported_query_formats,
                extent_wgs84_json = excluded.extent_wgs84_json, ogc_json = excluded.ogc_json, fetched_at = excluded.fetched_at
            RETURNING id;
            """, [.int(serverID), .string(name), .string(type.name), .string(url.absoluteString),
                  .string(detail.operations.joined(separator: ",")), .optional(detail.countDefault),
                  .string(detail.formats.joined(separator: ",")), .optional(extent?.json), .string(json),
                  fetchedAt.bindValue]).rows.first?.first?.int64
        guard let id else { throw MetadataStoreError.unexpectedRow("ogc service insert") }
        return try service(id: id)
    }

    /// Records the layers a capabilities document lists under a service, matched to existing
    /// rows by `ogc_name` so a re-crawl keeps ids (and the downloads hanging off them) stable.
    /// Layers no longer listed are dropped with everything beneath them.
    @discardableResult
    public func upsertOGCLayers(serviceID: Int64, document: OGCCapabilitiesDocument, fetchedAt: Date = Date()) throws -> [LayerRecord] {
        let typeLabel: String
        switch document.type { case .wfs: typeLabel = "Feature type"; case .wms: typeLabel = "WMS layer"; case .wmts: typeLabel = "WMTS layer"; default: typeLabel = "Layer" }
        var ids = [Int64]()
        try execScript("BEGIN IMMEDIATE;")
        do {
            for (index, layer) in document.layers.enumerated() {
                let json = try String(decoding: JSONEncoder().encode(layer), as: UTF8.self)
                let raw = index < document.layerXML.count ? document.layerXML[index] : ""
                let wkid = layer.defaultCRS.flatMap(OGCURL.epsgCode)
                let existing = try query("SELECT id FROM layer WHERE service_id = ? AND ogc_name = ?;",
                                         [.int(serviceID), .string(layer.name)]).rows.first?.first?.int64
                if let existing {
                    try query("""
                        UPDATE layer SET name = ?, type = ?, geometry_type = COALESCE(?, geometry_type), extent_wgs84_json = ?,
                            wkid = ?, supported_query_formats = ?, capabilities = ?, raw_json = ?, ogc_json = ?, fetched_at = ?
                        WHERE id = ?;
                        """, [.string(layer.title), .string(typeLabel), .optional(layer.geometryType), .optional(layer.bboxWGS84?.json),
                              .optional(wkid), .string(layer.formats.joined(separator: ",")), .string(document.type == .wfs ? "Query" : ""),
                              .string(raw), .string(json), fetchedAt.bindValue, .int(existing)])
                    ids.append(existing)
                } else {
                    let next = (try query("SELECT COALESCE(MAX(layer_id), -1) + 1 FROM layer WHERE service_id = ?;", [.int(serviceID)])
                        .rows.first?.first?.int64) ?? 0
                    let id = try query("""
                        INSERT INTO layer (service_id, layer_id, name, type, is_table, geometry_type, extent_wgs84_json, wkid,
                            supported_query_formats, capabilities, raw_json, ogc_name, ogc_json, fetched_at)
                        VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id;
                        """, [.int(serviceID), .int(next), .string(layer.title), .string(typeLabel), .optional(layer.geometryType),
                              .optional(layer.bboxWGS84?.json), .optional(wkid), .string(layer.formats.joined(separator: ",")),
                              .string(document.type == .wfs ? "Query" : ""), .string(raw), .string(layer.name), .string(json),
                              fetchedAt.bindValue]).rows.first?.first?.int64
                    guard let id else { throw MetadataStoreError.unexpectedRow("ogc layer insert") }
                    ids.append(id)
                }
            }
            try execScript("COMMIT;")
        } catch {
            _ = try? execScript("ROLLBACK;")
            throw error
        }
        let keep = try ids.map { try layer(id: $0) }
        try pruneLayers(serviceID: serviceID, keeping: keep.map(\.layerID))
        return keep
    }

    /// Replaces a WFS feature type's fields with what DescribeFeatureType said, and records
    /// its geometry type. The geometry field itself is kept as a field of Esri type geometry,
    /// as ArcGIS layers do, so the Fields tab and the exporter treat both alike.
    public func setOGCFields(layerID: Int64, fields: [OGCField]) throws {
        try execScript("BEGIN IMMEDIATE;")
        do {
            try query("DELETE FROM field WHERE layer_id = ?;", [.int(layerID)])
            for (position, field) in fields.enumerated() {
                let type = field.esriType
                try query("""
                    INSERT INTO field (layer_id, position, name, alias, esri_type, duck_type, length, nullable, editable, domain_json)
                    VALUES (?, ?, ?, NULL, ?, ?, NULL, ?, NULL, NULL);
                    """, [.int(layerID), .int(Int64(position)), .string(field.name), .string(type.rawValue),
                          .string(type.duckType ?? "SKIP"), .optional(field.nillable)])
            }
            if let geometry = fields.first(where: \.isGeometry) {
                try query("UPDATE layer SET geometry_type = ? WHERE id = ?;", [.optional(geometry.geometryType), .int(layerID)])
                if var detail = try layer(id: layerID).ogcDetail {
                    detail.geometryType = geometry.geometryType
                    let json = try String(decoding: JSONEncoder().encode(detail), as: UTF8.self)
                    try query("UPDATE layer SET ogc_json = ? WHERE id = ?;", [.string(json), .int(layerID)])
                }
            }
            try execScript("COMMIT;")
        } catch {
            _ = try? execScript("ROLLBACK;")
            throw error
        }
    }

    /// The layer an OGC request name points at, under a service.
    public func layer(serviceID: Int64, ogcName: String) throws -> LayerRecord? {
        let local = ogcName.split(separator: ":").last.map(String.init) ?? ogcName
        return try layers(serviceID: serviceID).first { $0.ogcName == ogcName }
            ?? layers(serviceID: serviceID).first { ($0.ogcName ?? "").split(separator: ":").last.map(String.init) == local }
    }
}
