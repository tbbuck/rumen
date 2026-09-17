import Foundation
import SQLiteKit

public enum MetadataStoreError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case unexpectedRow(String)

    public var description: String {
        switch self {
        case .notFound(let what): return "\(what) not found"
        case .unexpectedRow(let what): return "unexpected row shape reading \(what)"
        }
    }
}

/// Persistence for crawled metadata (SPEC §5.2, §7.2). Every write goes through a prepared
/// statement; raw JSON is stored verbatim next to the normalised columns.
extension AppDatabase {

    // MARK: - Servers

    private static let serverColumns = """
        id, root_url, friendly_name, origin_override, referer_override, auth_kind, username,
        token_service_url, arcgis_version, created_at, last_visited_at, last_deep_crawl_at, cookie, kind
        """

    /// Registers a server root, or touches `last_visited_at` on an existing one. The friendly
    /// name and the kind are only used for a new row — renames go through `renameServer`.
    @discardableResult
    public func addServer(rootURL: URL, friendlyName: String, kind: ServerKind = .arcgis, now: Date = Date()) throws -> ServerRecord {
        let name = friendlyName.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = try query("""
            INSERT INTO server (root_url, friendly_name, created_at, last_visited_at, kind)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (root_url) DO UPDATE SET last_visited_at = excluded.last_visited_at
            RETURNING id;
            """, [.string(rootURL.absoluteString), .string(name.isEmpty ? (rootURL.host ?? "server") : name),
                  now.bindValue, now.bindValue, .string(kind.rawValue)]).rows.first?.first?.int64
        guard let id else { throw MetadataStoreError.unexpectedRow("server insert") }
        return try server(id: id)
    }

    /// All servers, most recently visited first.
    public func servers() throws -> [ServerRecord] {
        try query("SELECT \(Self.serverColumns) FROM server ORDER BY last_visited_at DESC NULLS LAST, id;")
            .rows.map(Self.serverRecord)
    }

    public func server(id: Int64) throws -> ServerRecord {
        guard let row = try query("SELECT \(Self.serverColumns) FROM server WHERE id = ?;", [.int(id)]).rows.first
        else { throw MetadataStoreError.notFound("server \(id)") }
        return try Self.serverRecord(row)
    }

    public func server(rootURL: URL) throws -> ServerRecord? {
        try query("SELECT \(Self.serverColumns) FROM server WHERE root_url = ?;",
                  [.string(rootURL.absoluteString)]).rows.first.map(Self.serverRecord)
    }

    public func renameServer(id: Int64, friendlyName: String) throws {
        try query("UPDATE server SET friendly_name = ? WHERE id = ?;", [.string(friendlyName), .int(id)])
    }

    /// Blank overrides are stored as NULL (meaning "use the default").
    public func setHeaderOverrides(serverID: Int64, origin: String?, referer: String?) throws {
        func clean(_ s: String?) -> SQLBind {
            let t = s?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? .null : .string(t)
        }
        try query("UPDATE server SET origin_override = ?, referer_override = ? WHERE id = ?;",
                  [clean(origin), clean(referer), .int(serverID)])
    }

    public func setServerVersion(id: Int64, version: Double?) throws {
        try query("UPDATE server SET arcgis_version = ? WHERE id = ?;", [.optional(version), .int(id)])
    }

    public func markDeepCrawl(serverID: Int64, at date: Date = Date()) throws {
        try query("UPDATE server SET last_deep_crawl_at = ? WHERE id = ?;", [date.bindValue, .int(serverID)])
    }

    /// Removes a server and everything cached beneath it. Download *records* go too; files
    /// on disk are never touched.
    public func forgetServer(id: Int64) throws {
        try execScript("BEGIN IMMEDIATE;")
        do {
            let layersOf = "SELECT l.id FROM layer l JOIN service s ON s.id = l.service_id WHERE s.server_id = ?"
            try query("DELETE FROM export WHERE download_id IN (SELECT d.id FROM download d WHERE d.layer_id IN (\(layersOf)));", [.int(id)])
            try query("DELETE FROM download_chunk WHERE download_id IN (SELECT d.id FROM download d WHERE d.layer_id IN (\(layersOf)));", [.int(id)])
            try query("DELETE FROM download WHERE layer_id IN (\(layersOf));", [.int(id)])
            try query("DELETE FROM query_history WHERE layer_id IN (\(layersOf));", [.int(id)])
            try query("DELETE FROM field WHERE layer_id IN (\(layersOf));", [.int(id)])
            try query("DELETE FROM layer WHERE service_id IN (SELECT id FROM service WHERE server_id = ?);", [.int(id)])
            try query("DELETE FROM service WHERE server_id = ?;", [.int(id)])
            try query("DELETE FROM folder WHERE server_id = ?;", [.int(id)])
            try query("DELETE FROM server WHERE id = ?;", [.int(id)])
            try execScript("COMMIT;")
        } catch {
            _ = try? execScript("ROLLBACK;")
            throw error
        }
    }

    private static func serverRecord(_ r: [SQLValue]) throws -> ServerRecord {
        guard r.count == 14, let id = r[0].int64, let urlText = r[1].stringValue, let url = URL(string: urlText),
              let name = r[2].stringValue, let auth = r[5].stringValue, let created = r[9].dateFromMicros
        else { throw MetadataStoreError.unexpectedRow("server") }
        return ServerRecord(id: id, rootURL: url, friendlyName: name, originOverride: r[3].stringValue,
                            refererOverride: r[4].stringValue, authKind: auth, username: r[6].stringValue,
                            tokenServiceURL: r[7].stringValue, arcgisVersion: r[8].doubleValue, createdAt: created,
                            lastVisitedAt: r[10].dateFromMicros, lastDeepCrawlAt: r[11].dateFromMicros,
                            cookie: r[12].stringValue, kind: r[13].stringValue.flatMap(ServerKind.init(rawValue:)) ?? .arcgis)
    }

    /// Blank clears it.
    public func setCookie(serverID: Int64, cookie: String?) throws {
        let trimmed = cookie?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bind: SQLBind = trimmed.isEmpty ? .null : .string(trimmed)
        try query("UPDATE server SET cookie = ? WHERE id = ?;", [bind, .int(serverID)])
    }

    // MARK: - Folders

    private static let folderColumns = "id, server_id, path, parent_path, name, last_error, fetched_at"

    /// Records the folders a directory lists, by full path. Existing rows keep their outcome.
    @discardableResult
    public func upsertFolders(serverID: Int64, parentPath: String, paths: [String]) throws -> [FolderRecord] {
        var records = [FolderRecord]()
        for path in paths {
            let id = try query("""
                INSERT INTO folder (server_id, path, parent_path, name) VALUES (?, ?, ?, ?)
                ON CONFLICT (server_id, path) DO UPDATE SET parent_path = excluded.parent_path, name = excluded.name
                RETURNING id;
                """, [.int(serverID), .string(path), .string(parentPath), .string(Self.folderName(path))]).rows.first?.first?.int64
            guard let id else { throw MetadataStoreError.unexpectedRow("folder insert") }
            records.append(try folder(id: id))
        }
        return records
    }

    /// Drops folders directly under `parentPath` that are not in `keeping`, with their
    /// sub-folders and the services beneath them: the reconcile step after a fresh listing.
    public func pruneFolders(serverID: Int64, parentPath: String, keeping paths: [String]) throws {
        let keep = Set(paths)
        let current = try query("SELECT path FROM folder WHERE server_id = ? AND parent_path = ?;",
                                [.int(serverID), .string(parentPath)]).rows
        for row in current {
            guard let path = row[0].stringValue, !keep.contains(path) else { continue }
            try deleteFolder(serverID: serverID, path: path)
        }
    }

    /// Removes a folder, its sub-folders, and every service under them.
    public func deleteFolder(serverID: Int64, path: String) throws {
        let below = Self.likePrefix(path) + "/%"
        let services = try query("SELECT id FROM service WHERE server_id = ? AND (folder_path = ? OR folder_path LIKE ? ESCAPE '\\');",
                                 [.int(serverID), .string(path), .string(below)]).rows
        for row in services { if let id = row[0].int64 { try deleteService(id: id) } }
        try query("DELETE FROM folder WHERE server_id = ? AND (path = ? OR path LIKE ? ESCAPE '\\');",
                  [.int(serverID), .string(path), .string(below)])
    }

    /// The folder was listed: clears its error and stamps the time. Makes the row if the folder
    /// was reached directly (a pasted URL) rather than through its parent's listing.
    public func markFolderListed(serverID: Int64, path: String, at date: Date = Date()) throws {
        guard !path.isEmpty else { return }
        try query("""
            INSERT INTO folder (server_id, path, parent_path, name, last_error, fetched_at) VALUES (?, ?, ?, ?, NULL, ?)
            ON CONFLICT (server_id, path) DO UPDATE SET last_error = NULL, fetched_at = excluded.fetched_at;
            """, [.int(serverID), .string(path), .string(Self.parentPath(path)), .string(Self.folderName(path)), date.bindValue])
    }

    /// The folder could not be listed: keeps whatever was cached beneath it and records why.
    public func markFolderFailed(serverID: Int64, path: String, error: String) throws {
        guard !path.isEmpty else { return }
        try query("""
            INSERT INTO folder (server_id, path, parent_path, name, last_error) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT (server_id, path) DO UPDATE SET last_error = excluded.last_error;
            """, [.int(serverID), .string(path), .string(Self.parentPath(path)), .string(Self.folderName(path)), .string(error)])
    }

    /// Every recorded folder of a server, by path.
    public func folders(serverID: Int64) throws -> [FolderRecord] {
        try query("SELECT \(Self.folderColumns) FROM folder WHERE server_id = ? ORDER BY path;", [.int(serverID)])
            .rows.compactMap(Self.folderRecord)
    }

    public func folder(id: Int64) throws -> FolderRecord {
        guard let row = try query("SELECT \(Self.folderColumns) FROM folder WHERE id = ?;", [.int(id)]).rows.first,
              let record = Self.folderRecord(row) else { throw MetadataStoreError.notFound("folder \(id)") }
        return record
    }

    /// Folders in scope whose last listing failed: what the tree, the deep crawl, and column
    /// search cannot see. nil = every server.
    public func failedFolders(serverID: Int64? = nil) throws -> [FolderRecord] {
        let scope = serverID.map { " AND server_id = \($0)" } ?? ""
        return try query("SELECT \(Self.folderColumns) FROM folder WHERE last_error IS NOT NULL\(scope) ORDER BY server_id, path;")
            .rows.compactMap(Self.folderRecord)
    }

    private static func folderRecord(_ r: [SQLValue]) -> FolderRecord? {
        guard r.count == 7, let id = r[0].int64, let serverID = r[1].int64, let path = r[2].stringValue,
              let parent = r[3].stringValue, let name = r[4].stringValue else { return nil }
        return FolderRecord(id: id, serverID: serverID, path: path, parentPath: parent, name: name,
                            lastError: r[5].stringValue, fetchedAt: r[6].dateFromMicros)
    }

    static func folderName(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? path }

    static func parentPath(_ path: String) -> String {
        path.split(separator: "/").dropLast().joined(separator: "/")
    }

    static func likePrefix(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    // MARK: - Services

    private static let serviceColumns = """
        id, server_id, folder_path, name, type, url, capabilities, max_record_count,
        supported_query_formats, is_tile_cache, fetched_at, extent_wgs84_json, ogc_json
        """

    /// Records the services listed in a directory (root or folder). New rows get their URL
    /// from the server root; existing rows keep their crawled detail. Returns the records in
    /// listing order.
    @discardableResult
    public func upsertServices(serverID: Int64, rootURL: URL, folderPath: String,
                               entries: [ServiceDirectory.Entry]) throws -> [ServiceRecord] {
        var ids = [Int64]()
        for entry in entries {
            let type = entry.serviceType
            let url = rootURL.appendingPathComponent(entry.name).appendingPathComponent(type.name)
            let id = try query("""
                INSERT INTO service (server_id, folder_path, name, type, url)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (server_id, url) DO UPDATE SET name = excluded.name, folder_path = excluded.folder_path
                RETURNING id;
                """, [.int(serverID), .string(folderPath), .string(entry.name), .string(type.name),
                      .string(url.absoluteString)]).rows.first?.first?.int64
            guard let id else { throw MetadataStoreError.unexpectedRow("service insert") }
            ids.append(id)
        }
        return try ids.map { try service(id: $0) }
    }

    /// Drops services in `folderPath` whose URL is not in `keeping` — the reconcile step after
    /// a fresh directory listing. Their layers, fields, and download records go with them.
    public func pruneServices(serverID: Int64, folderPath: String, keeping urls: [URL]) throws {
        let current = try query("SELECT id, url FROM service WHERE server_id = ? AND folder_path = ?;",
                                [.int(serverID), .string(folderPath)]).rows
        let keep = Set(urls.map(\.absoluteString))
        for row in current {
            guard let id = row[0].int64, let url = row[1].stringValue, !keep.contains(url) else { continue }
            try deleteService(id: id)
        }
    }

    public func deleteService(id: Int64) throws {
        let layersOf = "SELECT id FROM layer WHERE service_id = ?"
        try query("DELETE FROM export WHERE download_id IN (SELECT d.id FROM download d WHERE d.layer_id IN (\(layersOf)));", [.int(id)])
        try query("DELETE FROM download_chunk WHERE download_id IN (SELECT d.id FROM download d WHERE d.layer_id IN (\(layersOf)));", [.int(id)])
        try query("DELETE FROM download WHERE layer_id IN (\(layersOf));", [.int(id)])
        try query("DELETE FROM query_history WHERE layer_id IN (\(layersOf));", [.int(id)])
        try query("DELETE FROM field WHERE layer_id IN (\(layersOf));", [.int(id)])
        try query("DELETE FROM layer WHERE service_id = ?;", [.int(id)])
        try query("DELETE FROM service WHERE id = ?;", [.int(id)])
    }

    /// Stores a fetched service definition (and its verbatim JSON).
    public func updateService(id: Int64, info: ServiceInfo, raw: Data, extentWGS84: BoundingBox? = nil,
                              fetchedAt: Date = Date()) throws {
        try query("""
            UPDATE service SET capabilities = ?, max_record_count = ?, supported_query_formats = ?,
                is_tile_cache = ?, raw_json = ?, fetched_at = ?, extent_wgs84_json = ?
            WHERE id = ?;
            """, [.optional(info.capabilities), .optional(info.maxRecordCount), .optional(info.supportedQueryFormats),
                  .bool(info.isTileCache), .string(String(decoding: raw, as: UTF8.self)), fetchedAt.bindValue,
                  .optional(extentWGS84?.json), .int(id)])
    }

    public func services(serverID: Int64) throws -> [ServiceRecord] {
        try query("SELECT \(Self.serviceColumns) FROM service WHERE server_id = ? ORDER BY folder_path, name, type;",
                  [.int(serverID)]).rows.map(Self.serviceRecord)
    }

    public func services(serverID: Int64, folderPath: String) throws -> [ServiceRecord] {
        try query("SELECT \(Self.serviceColumns) FROM service WHERE server_id = ? AND folder_path = ? ORDER BY name, type;",
                  [.int(serverID), .string(folderPath)]).rows.map(Self.serviceRecord)
    }

    public func service(id: Int64) throws -> ServiceRecord {
        guard let row = try query("SELECT \(Self.serviceColumns) FROM service WHERE id = ?;", [.int(id)]).rows.first
        else { throw MetadataStoreError.notFound("service \(id)") }
        return try Self.serviceRecord(row)
    }

    public func service(serverID: Int64, url: URL) throws -> ServiceRecord? {
        try query("SELECT \(Self.serviceColumns) FROM service WHERE server_id = ? AND url = ?;",
                  [.int(serverID), .string(url.absoluteString)]).rows.first.map(Self.serviceRecord)
    }

    public func serviceRawJSON(id: Int64) throws -> String? {
        try query("SELECT raw_json FROM service WHERE id = ?;", [.int(id)]).rows.first?.first?.stringValue
    }

    private static func serviceRecord(_ r: [SQLValue]) throws -> ServiceRecord {
        guard r.count == 13, let id = r[0].int64, let serverID = r[1].int64, let folder = r[2].stringValue,
              let name = r[3].stringValue, let type = r[4].stringValue, let urlText = r[5].stringValue,
              let url = URL(string: urlText)
        else { throw MetadataStoreError.unexpectedRow("service") }
        return ServiceRecord(id: id, serverID: serverID, folderPath: folder, name: name, type: ServiceType(type),
                             url: url, capabilities: r[6].stringValue, maxRecordCount: r[7].intValue,
                             supportedQueryFormats: r[8].stringValue, isTileCache: r[9].boolValue,
                             extentWGS84: BoundingBox(json: r[11].stringValue), fetchedAt: r[10].dateFromMicros,
                             ogcJSON: r[12].stringValue)
    }

    // MARK: - Layers

    private static let layerColumns = """
        id, service_id, layer_id, name, type, is_table, geometry_type, parent_layer_id, object_id_field,
        global_id_field, has_z, has_m, has_attachments, extent_json, wkid, latest_wkid, max_record_count,
        supported_query_formats, capabilities, supports_pagination, supports_statistics, supports_order_by,
        supports_result_type, transport, extractable, extractable_reason, sibling_layer_id, feature_count,
        feature_count_at, fetched_at, extent_wgs84_json, ogc_name, ogc_json
        """

    /// Records the layers and tables a service lists. Existing rows keep their crawled detail.
    @discardableResult
    public func upsertLayers(serviceID: Int64, layers: [LayerSummary], tables: [LayerSummary]) throws -> [LayerRecord] {
        var ids = [Int64]()
        for (summary, isTable) in layers.map({ ($0, false) }) + tables.map({ ($0, true) }) {
            let id = try query("""
                INSERT INTO layer (service_id, layer_id, name, type, is_table, geometry_type, parent_layer_id)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (service_id, layer_id) DO UPDATE SET
                    name = excluded.name, type = excluded.type, is_table = excluded.is_table,
                    geometry_type = excluded.geometry_type, parent_layer_id = excluded.parent_layer_id
                RETURNING id;
                """, [.int(serviceID), .int(Int64(summary.id)), .string(summary.name),
                      .optional(summary.type ?? (isTable ? "Table" : nil)), .bool(isTable),
                      .optional(summary.geometryType), .optional(summary.parentID)]).rows.first?.first?.int64
            guard let id else { throw MetadataStoreError.unexpectedRow("layer insert") }
            ids.append(id)
        }
        return try ids.map { try layer(id: $0) }
    }

    /// Drops layers of a service not in `keeping` (by ArcGIS layer id).
    public func pruneLayers(serviceID: Int64, keeping layerIDs: [Int]) throws {
        let current = try query("SELECT id, layer_id FROM layer WHERE service_id = ?;", [.int(serviceID)]).rows
        let keep = Set(layerIDs)
        for row in current {
            guard let id = row[0].int64, let layerID = row[1].intValue, !keep.contains(layerID) else { continue }
            try query("DELETE FROM export WHERE download_id IN (SELECT id FROM download WHERE layer_id = ?);", [.int(id)])
            try query("DELETE FROM download_chunk WHERE download_id IN (SELECT id FROM download WHERE layer_id = ?);", [.int(id)])
            try query("DELETE FROM download WHERE layer_id = ?;", [.int(id)])
            try query("DELETE FROM query_history WHERE layer_id = ?;", [.int(id)])
            try query("DELETE FROM field WHERE layer_id = ?;", [.int(id)])
            try query("DELETE FROM layer WHERE id = ?;", [.int(id)])
        }
    }

    /// Stores a fetched layer definition, its verbatim JSON, and replaces its fields.
    public func updateLayer(id: Int64, info: LayerInfo, raw: Data, extentWGS84: BoundingBox? = nil,
                            fetchedAt: Date = Date()) throws {
        let sr = info.spatialReference
        try execScript("BEGIN IMMEDIATE;")
        do {
            try query("""
                UPDATE layer SET name = ?, type = ?, is_table = ?, geometry_type = ?, parent_layer_id = ?,
                    object_id_field = ?, global_id_field = ?, has_z = ?, has_m = ?, has_attachments = ?,
                    extent_json = ?, wkid = ?, latest_wkid = ?, max_record_count = ?, supported_query_formats = ?,
                    capabilities = ?, supports_pagination = ?, supports_statistics = ?, supports_order_by = ?,
                    supports_result_type = ?, raw_json = ?, fetched_at = ?, extent_wgs84_json = ?
                WHERE id = ?;
                """, [.string(info.name), .optional(info.type), .bool(info.isTable), .optional(info.geometryType),
                      .optional(info.parentLayer?.id), .optional(info.oidField), .optional(info.globalIdField),
                      .optional(info.hasZ), .optional(info.hasM), .optional(info.hasAttachments),
                      .optional(Self.extentJSON(info.extent)), .optional(sr?.wkid), .optional(sr?.latestWkid),
                      .optional(info.maxRecordCount), .optional(info.supportedQueryFormats), .optional(info.capabilities),
                      .bool(info.canPaginate), .bool(info.canStatistics), .bool(info.canOrderBy),
                      .optional(info.advancedQueryCapabilities?.supportsQueryWithResultType),
                      .string(String(decoding: raw, as: UTF8.self)), fetchedAt.bindValue,
                      .optional(extentWGS84?.json), .int(id)])
            try query("DELETE FROM field WHERE layer_id = ?;", [.int(id)])
            for (position, field) in info.fields.enumerated() {
                try query("""
                    INSERT INTO field (layer_id, position, name, alias, esri_type, duck_type, length, nullable, editable, domain_json)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [.int(id), .int(Int64(position)), .string(field.name), .optional(field.alias),
                          .string(field.type.rawValue), .string(field.type.duckType ?? "SKIP"),
                          .optional(field.length), .optional(field.nullable), .optional(field.editable),
                          .optional(Self.json(field.domain))])
            }
            try execScript("COMMIT;")
        } catch {
            _ = try? execScript("ROLLBACK;")
            throw error
        }
    }

    public func setFeatureCount(layerID: Int64, count: Int64, at date: Date = Date()) throws {
        try query("UPDATE layer SET feature_count = ?, feature_count_at = ? WHERE id = ?;",
                  [.int(count), date.bindValue, .int(layerID)])
    }

    public func setExtractability(layerID: Int64, extractable: Bool?, reason: String?, transport: String?,
                                  siblingLayerID: Int64?) throws {
        try query("""
            UPDATE layer SET extractable = ?, extractable_reason = ?, transport = ?, sibling_layer_id = ? WHERE id = ?;
            """, [.optional(extractable), .optional(reason), .optional(transport), .optional(siblingLayerID), .int(layerID)])
    }

    /// Every layer under a server, grouped by service, in one query: the tree needs them all.
    public func layersByService(serverID: Int64) throws -> [Int64: [LayerRecord]] {
        let rows = try query("""
            SELECT \(Self.layerColumns) FROM layer
            WHERE service_id IN (SELECT id FROM service WHERE server_id = ?)
            ORDER BY service_id, is_table, layer_id;
            """, [.int(serverID)]).rows
        var grouped = [Int64: [LayerRecord]]()
        for row in rows {
            let record = try Self.layerRecord(row)
            grouped[record.serviceID, default: []].append(record)
        }
        return grouped
    }

    public func layers(serviceID: Int64) throws -> [LayerRecord] {
        try query("SELECT \(Self.layerColumns) FROM layer WHERE service_id = ? ORDER BY is_table, layer_id;",
                  [.int(serviceID)]).rows.map(Self.layerRecord)
    }

    public func layer(id: Int64) throws -> LayerRecord {
        guard let row = try query("SELECT \(Self.layerColumns) FROM layer WHERE id = ?;", [.int(id)]).rows.first
        else { throw MetadataStoreError.notFound("layer \(id)") }
        return try Self.layerRecord(row)
    }

    public func layer(serviceID: Int64, layerID: Int) throws -> LayerRecord? {
        try query("SELECT \(Self.layerColumns) FROM layer WHERE service_id = ? AND layer_id = ?;",
                  [.int(serviceID), .int(Int64(layerID))]).rows.first.map(Self.layerRecord)
    }

    public func layerRawJSON(id: Int64) throws -> String? {
        try query("SELECT raw_json FROM layer WHERE id = ?;", [.int(id)]).rows.first?.first?.stringValue
    }

    public func fields(layerID: Int64) throws -> [FieldRecord] {
        try query("""
            SELECT id, layer_id, position, name, alias, esri_type, duck_type, length, nullable, editable, domain_json
            FROM field WHERE layer_id = ? ORDER BY position;
            """, [.int(layerID)]).rows.map(Self.fieldRecord)
    }

    private static func layerRecord(_ r: [SQLValue]) throws -> LayerRecord {
        guard r.count == 33, let id = r[0].int64, let serviceID = r[1].int64, let layerID = r[2].intValue,
              let name = r[3].stringValue, let isTable = r[5].boolValue
        else { throw MetadataStoreError.unexpectedRow("layer") }
        return LayerRecord(
            id: id, serviceID: serviceID, layerID: layerID, name: name, type: r[4].stringValue, isTable: isTable,
            geometryType: r[6].stringValue, parentLayerID: r[7].intValue, objectIdField: r[8].stringValue,
            globalIdField: r[9].stringValue, hasZ: r[10].boolValue, hasM: r[11].boolValue,
            hasAttachments: r[12].boolValue, extentJSON: r[13].stringValue, wkid: r[14].intValue,
            latestWkid: r[15].intValue, maxRecordCount: r[16].intValue, supportedQueryFormats: r[17].stringValue,
            capabilities: r[18].stringValue, supportsPagination: r[19].boolValue, supportsStatistics: r[20].boolValue,
            supportsOrderBy: r[21].boolValue, supportsResultType: r[22].boolValue, transport: r[23].stringValue,
            extractable: r[24].boolValue, extractableReason: r[25].stringValue, siblingLayerID: r[26].int64,
            featureCount: r[27].int64, featureCountAt: r[28].dateFromMicros,
            extentWGS84: BoundingBox(json: r[30].stringValue), fetchedAt: r[29].dateFromMicros,
            ogcName: r[31].stringValue, ogcJSON: r[32].stringValue)
    }

    private static func fieldRecord(_ r: [SQLValue]) throws -> FieldRecord {
        guard r.count == 11, let id = r[0].int64, let layerID = r[1].int64, let position = r[2].intValue,
              let name = r[3].stringValue, let esri = r[5].stringValue, let duck = r[6].stringValue
        else { throw MetadataStoreError.unexpectedRow("field") }
        return FieldRecord(id: id, layerID: layerID, position: position, name: name, alias: r[4].stringValue,
                           esriType: EsriFieldType(rawValue: esri), duckType: duck, length: r[7].intValue,
                           nullable: r[8].boolValue, editable: r[9].boolValue, domainJSON: r[10].stringValue)
    }

    // MARK: - JSON helpers

    /// Compact `{"xmin":…,"ymin":…,"xmax":…,"ymax":…,"wkid":…}`; nil for an empty extent.
    static func extentJSON(_ extent: Extent?) -> String? {
        guard let e = extent, let xmin = e.xmin, let ymin = e.ymin, let xmax = e.xmax, let ymax = e.ymax else { return nil }
        var parts = ["\"xmin\":\(xmin)", "\"ymin\":\(ymin)", "\"xmax\":\(xmax)", "\"ymax\":\(ymax)"]
        if let wkid = e.spatialReference?.effectiveWkid { parts.append("\"wkid\":\(wkid)") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func json(_ value: JSONValue?) -> String? {
        guard let value, !value.isNull, let data = try? JSONEncoder().encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Query history

public struct QueryHistoryRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let layerID: Int64
    public let whereClause: String
    public let outFields: String?
    public let ranAt: Date
    public let count: Int64?
    public let durationMillis: Int64?

    public init(id: Int64, layerID: Int64, whereClause: String, outFields: String?, ranAt: Date, count: Int64?, durationMillis: Int64?) {
        self.id = id
        self.layerID = layerID
        self.whereClause = whereClause
        self.outFields = outFields
        self.ranAt = ranAt
        self.count = count
        self.durationMillis = durationMillis
    }
}

extension AppDatabase {
    /// Records a query that ran (count or preview) against a layer.
    @discardableResult
    public func recordQuery(layerID: Int64, whereClause: String, outFields: String?, count: Int64?,
                            durationMillis: Int64?, at date: Date = Date()) throws -> QueryHistoryRecord {
        let id = try query("""
            INSERT INTO query_history (layer_id, where_clause, out_fields, ran_at, count, duration_ms)
            VALUES (?, ?, ?, ?, ?, ?) RETURNING id;
            """, [.int(layerID), .string(whereClause), .optional(outFields), date.bindValue,
                  .optional(count), .optional(durationMillis)]).rows.first?.first?.int64
        guard let id else { throw MetadataStoreError.unexpectedRow("query_history insert") }
        return QueryHistoryRecord(id: id, layerID: layerID, whereClause: whereClause, outFields: outFields,
                                  ranAt: date, count: count, durationMillis: durationMillis)
    }

    /// Most recent first.
    public func queryHistory(layerID: Int64, limit: Int = 50) throws -> [QueryHistoryRecord] {
        try query("""
            SELECT id, layer_id, where_clause, out_fields, ran_at, count, duration_ms
            FROM query_history WHERE layer_id = ? ORDER BY ran_at DESC, id DESC LIMIT ?;
            """, [.int(layerID), .int(Int64(limit))]).rows.map { r in
            QueryHistoryRecord(id: r[0].int64 ?? 0, layerID: r[1].int64 ?? 0, whereClause: r[2].stringValue ?? "",
                               outFields: r[3].stringValue, ranAt: r[4].dateFromMicros ?? Date(timeIntervalSince1970: 0),
                               count: r[5].int64, durationMillis: r[6].int64)
        }
    }
}

extension AppDatabase {
    /// Records the transport a download actually worked with (the PBF → JSON fallback sticks).
    public func setLayerTransport(layerID: Int64, transport: String) throws {
        try query("UPDATE layer SET transport = ? WHERE id = ?;", [.string(transport), .int(layerID)])
    }
}

// MARK: - Settings

extension AppDatabase {
    public func setting(_ key: String) throws -> String? {
        try query("SELECT value FROM setting WHERE key = ?;", [.string(key)]).rows.first?.first?.stringValue
    }

    public func setSetting(_ key: String, _ value: String?) throws {
        if let value {
            try query("INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value;",
                      [.string(key), .string(value)])
        } else {
            try query("DELETE FROM setting WHERE key = ?;", [.string(key)])
        }
    }
}
