import Foundation
import SQLiteKit

/// Export formats (SPEC §5.7). GeoParquet is the default and the one a download keeps; GeoJSON
/// and CSV are written from the staging table at download time or re-exported from a stored
/// GeoParquet later, without touching the server.
public enum ExportFormat: String, Sendable, CaseIterable, Equatable {
    case geoParquet = "geoparquet"
    case geoJSON = "geojson"
    case csv = "csv"
    /// A WMS GetMap picture (M10): PNG with a world file beside it, or GeoTIFF when the server offers it.
    case png = "png"
    case geoTIFF = "geotiff"

    public var fileExtension: String {
        switch self { case .geoParquet: "parquet"; case .geoJSON: "geojson"; case .csv: "csv"; case .png: "png"; case .geoTIFF: "tif" }
    }
    public var label: String {
        switch self { case .geoParquet: "GeoParquet"; case .geoJSON: "GeoJSON"; case .csv: "CSV"; case .png: "PNG image"; case .geoTIFF: "GeoTIFF" }
    }
    /// GeoJSON (RFC 7946) is always WGS 84; the spatial reference picker has no say.
    public var forcesWGS84: Bool { self == .geoJSON }
    /// A picture rather than features: no rows to store, nothing to re-export.
    public var isRaster: Bool { self == .png || self == .geoTIFF }
    /// The formats features can be written in.
    public static var vector: [ExportFormat] { [.geoParquet, .geoJSON, .csv] }
    /// Formats a stored GeoParquet can be re-exported to.
    public static var reexportable: [ExportFormat] { [.geoJSON, .csv] }
    /// The WMS media types an image format can be asked for as, best first. MapServer's
    /// `image/tiff` GetMap output is a GeoTIFF; GeoServer spells it `image/geotiff`.
    public var mediaTypes: [String] {
        switch self { case .png: ["image/png"]; case .geoTIFF: ["image/geotiff", "image/tiff"]; default: [] }
    }
    public var mediaType: String? { mediaTypes.first }
    /// The media type to request from a server that lists `formats`: the first of ours it
    /// offers, or our first when it lists none at all.
    public func offeredMediaType(in formats: [String]) -> String? {
        guard !mediaTypes.isEmpty else { return nil }
        if formats.isEmpty { return mediaTypes.first }
        let offered = formats.map { $0.lowercased() }
        return mediaTypes.first { candidate in offered.contains { $0 == candidate || $0.hasPrefix(candidate + ";") } }
    }
    /// How the geometry travels, for captions.
    public var geometryNote: String {
        switch self {
        case .geoParquet: "geometry as WKB with the CRS in the file's metadata"
        case .geoJSON: "written in WGS 84 as RFC 7946 requires"
        case .csv: "geometry as WKT in a geometry column"
        case .png: "a rendered picture with a world file beside it"
        case .geoTIFF: "a rendered picture with its georeferencing inside"
        }
    }
}

public enum DownloadStatus: String, Sendable, Equatable {
    case planned, running, paused, failed, cancelled, complete

    public var isFinished: Bool { self == .complete }
    /// Runs that can be picked up again.
    public var isResumable: Bool { [.paused, .failed, .cancelled, .planned].contains(self) }
}

public enum ChunkStatus: String, Sendable, Equatable {
    case pending, done, failed
    /// Replaced by smaller chunks after the server refused it whole.
    case split
}

/// A row of `download`.
public struct DownloadRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let layerID: Int64
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: DownloadStatus
    public let transport: Assessment.Transport
    public let strategy: Assessment.Strategy
    public let whereClause: String
    public let outWkid: Int
    public let format: ExportFormat
    public let domainLabels: Bool
    public var stagingPath: String?
    public var outputPath: String?
    public var outputSHA256: String?
    public var featureCount: Int64?
    public var invalidGeometryCount: Int64?
    public var bytes: Int64?
    public var error: String?

    public init(id: Int64, layerID: Int64, startedAt: Date, finishedAt: Date? = nil, status: DownloadStatus,
                transport: Assessment.Transport, strategy: Assessment.Strategy, whereClause: String, outWkid: Int,
                format: ExportFormat, domainLabels: Bool, stagingPath: String? = nil, outputPath: String? = nil,
                outputSHA256: String? = nil, featureCount: Int64? = nil, invalidGeometryCount: Int64? = nil,
                bytes: Int64? = nil, error: String? = nil) {
        self.id = id
        self.layerID = layerID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.transport = transport
        self.strategy = strategy
        self.whereClause = whereClause
        self.outWkid = outWkid
        self.format = format
        self.domainLabels = domainLabels
        self.stagingPath = stagingPath
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.featureCount = featureCount
        self.invalidGeometryCount = invalidGeometryCount
        self.bytes = bytes
        self.error = error
    }
}

/// A row of `download_chunk`: one request of the plan.
public struct DownloadChunk: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable { case offset, oidRange = "oid_range", oidList = "oid_list" }

    public let downloadID: Int64
    public let seq: Int
    public let kind: Kind
    public var lo: Int64?
    public var hi: Int64?
    public var offset: Int64?
    public var objectIDs: [Int64]?
    /// Page size for this chunk; nil means the run's page size.
    public var limit: Int?
    public var count: Int64?
    public var status: ChunkStatus
    public var attempts: Int
    public var lastError: String?

    public var id: Int { seq }

    public init(downloadID: Int64, seq: Int, kind: Kind, lo: Int64? = nil, hi: Int64? = nil, offset: Int64? = nil,
                objectIDs: [Int64]? = nil, limit: Int? = nil, count: Int64? = nil, status: ChunkStatus = .pending,
                attempts: Int = 0, lastError: String? = nil) {
        self.downloadID = downloadID
        self.seq = seq
        self.kind = kind
        self.lo = lo
        self.hi = hi
        self.offset = offset
        self.objectIDs = objectIDs
        self.limit = limit
        self.count = count
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
    }
}

// MARK: - Store

extension AppDatabase {
    private static let downloadColumns = """
        id, layer_id, started_at, finished_at, status, transport, strategy, where_clause, out_wkid, format,
        domain_labels, staging_path, output_path, output_sha256, feature_count, invalid_geometry_count, bytes, error
        """

    public func createDownload(layerID: Int64, transport: Assessment.Transport, strategy: Assessment.Strategy,
                               whereClause: String, outWkid: Int, format: ExportFormat, domainLabels: Bool,
                               startedAt: Date = Date()) throws -> DownloadRecord {
        let id = try query("""
            INSERT INTO download (layer_id, started_at, status, transport, strategy, where_clause, out_wkid, format, domain_labels)
            VALUES (?, ?, 'planned', ?, ?, ?, ?, ?, ?) RETURNING id;
            """, [.int(layerID), startedAt.bindValue, .string(transport.rawValue), .string(strategy.rawValue),
                  .string(whereClause), .int(Int64(outWkid)), .string(format.rawValue), .bool(domainLabels)]).rows.first?.first?.int64
        guard let id else { throw MetadataStoreError.unexpectedRow("download insert") }
        return try download(id: id)
    }

    public func download(id: Int64) throws -> DownloadRecord {
        guard let row = try query("SELECT \(Self.downloadColumns) FROM download WHERE id = ?;", [.int(id)]).rows.first
        else { throw MetadataStoreError.notFound("download \(id)") }
        return try Self.downloadRecord(row)
    }

    /// Newest first.
    public func downloads(layerID: Int64? = nil, limit: Int = 200) throws -> [DownloadRecord] {
        if let layerID {
            return try query("SELECT \(Self.downloadColumns) FROM download WHERE layer_id = ? ORDER BY started_at DESC, id DESC LIMIT ?;",
                             [.int(layerID), .int(Int64(limit))]).rows.map(Self.downloadRecord)
        }
        return try query("SELECT \(Self.downloadColumns) FROM download ORDER BY started_at DESC, id DESC LIMIT ?;",
                         [.int(Int64(limit))]).rows.map(Self.downloadRecord)
    }

    /// Runs that did not finish: to offer Resume after a relaunch.
    public func unfinishedDownloads() throws -> [DownloadRecord] {
        try query("SELECT \(Self.downloadColumns) FROM download WHERE status <> 'complete' ORDER BY started_at DESC, id DESC;")
            .rows.map(Self.downloadRecord)
    }

    public func setDownloadStatus(id: Int64, status: DownloadStatus, error: String? = nil, finishedAt: Date? = nil) throws {
        try query("UPDATE download SET status = ?, error = ?, finished_at = ? WHERE id = ?;",
                  [.string(status.rawValue), .optional(error), finishedAt.bindValue, .int(id)])
    }

    public func setDownloadStaging(id: Int64, path: String) throws {
        try query("UPDATE download SET staging_path = ? WHERE id = ?;", [.string(path), .int(id)])
    }

    public func setDownloadOutput(id: Int64, path: String, sha256: String, featureCount: Int64, invalidGeometries: Int64,
                                  bytes: Int64, finishedAt: Date = Date()) throws {
        try query("""
            UPDATE download SET status = 'complete', output_path = ?, output_sha256 = ?, feature_count = ?,
                invalid_geometry_count = ?, bytes = ?, finished_at = ?, error = NULL, staging_path = NULL
            WHERE id = ?;
            """, [.string(path), .string(sha256), .int(featureCount), .int(invalidGeometries), .int(bytes),
                  finishedAt.bindValue, .int(id)])
    }

    public func deleteDownload(id: Int64) throws {
        try query("DELETE FROM export WHERE download_id = ?;", [.int(id)])
        try query("DELETE FROM download_chunk WHERE download_id = ?;", [.int(id)])
        try query("DELETE FROM download WHERE id = ?;", [.int(id)])
    }

    private static func downloadRecord(_ r: [SQLValue]) throws -> DownloadRecord {
        guard r.count == 18, let id = r[0].int64, let layerID = r[1].int64, let started = r[2].dateFromMicros,
              let status = r[4].stringValue.flatMap(DownloadStatus.init(rawValue:)),
              let transport = r[5].stringValue.flatMap(Assessment.Transport.init(rawValue:)),
              let strategy = r[6].stringValue.flatMap(Assessment.Strategy.init(rawValue:)),
              let whereClause = r[7].stringValue, let outWkid = r[8].intValue,
              let format = r[9].stringValue.flatMap(ExportFormat.init(rawValue:)), let labels = r[10].boolValue
        else { throw MetadataStoreError.unexpectedRow("download") }
        return DownloadRecord(id: id, layerID: layerID, startedAt: started, finishedAt: r[3].dateFromMicros, status: status,
                              transport: transport, strategy: strategy, whereClause: whereClause, outWkid: outWkid,
                              format: format, domainLabels: labels, stagingPath: r[11].stringValue,
                              outputPath: r[12].stringValue, outputSHA256: r[13].stringValue, featureCount: r[14].int64,
                              invalidGeometryCount: r[15].int64, bytes: r[16].int64, error: r[17].stringValue)
    }

    // MARK: Chunks

    public func insertChunks(_ chunks: [DownloadChunk]) throws {
        try execScript("BEGIN IMMEDIATE;")
        do {
            for c in chunks {
                try query("""
                    INSERT INTO download_chunk (download_id, seq, kind, lo, hi, "offset", object_ids, "limit", count, status, attempts, last_error)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [.int(c.downloadID), .int(Int64(c.seq)), .string(c.kind.rawValue), .optional(c.lo), .optional(c.hi),
                          .optional(c.offset), .optional(c.objectIDs.map { $0.map(String.init).joined(separator: ",") }),
                          .optional(c.limit), .optional(c.count), .string(c.status.rawValue), .int(Int64(c.attempts)), .optional(c.lastError)])
            }
            try execScript("COMMIT;")
        } catch {
            _ = try? execScript("ROLLBACK;")
            throw error
        }
    }

    public func chunks(downloadID: Int64) throws -> [DownloadChunk] {
        try query("""
            SELECT download_id, seq, kind, lo, hi, "offset", object_ids, "limit", count, status, attempts, last_error
            FROM download_chunk WHERE download_id = ? ORDER BY seq;
            """, [.int(downloadID)]).rows.map { r in
            DownloadChunk(downloadID: r[0].int64 ?? 0, seq: r[1].intValue ?? 0,
                          kind: r[2].stringValue.flatMap(DownloadChunk.Kind.init(rawValue:)) ?? .offset,
                          lo: r[3].int64, hi: r[4].int64, offset: r[5].int64,
                          objectIDs: r[6].stringValue.map { $0.split(separator: ",").compactMap { Int64($0) } },
                          limit: r[7].intValue, count: r[8].int64,
                          status: r[9].stringValue.flatMap(ChunkStatus.init(rawValue:)) ?? .pending,
                          attempts: r[10].intValue ?? 0, lastError: r[11].stringValue)
        }
    }

    public func updateChunk(downloadID: Int64, seq: Int, status: ChunkStatus, count: Int64?, attempts: Int, error: String?) throws {
        try query("""
            UPDATE download_chunk SET status = ?, count = ?, attempts = ?, last_error = ? WHERE download_id = ? AND seq = ?;
            """, [.string(status.rawValue), .optional(count), .int(Int64(attempts)), .optional(error), .int(downloadID), .int(Int64(seq))])
    }
}

// MARK: - Exports

/// A file re-exported from a stored download (M7): a row of `export`.
public struct ExportRecord: Sendable, Equatable, Identifiable {
    public let id: Int64
    public let downloadID: Int64
    public let format: ExportFormat
    public let outWkid: Int
    public let outputPath: String
    public let outputSHA256: String?
    public let bytes: Int64?
    public let featureCount: Int64?
    public let createdAt: Date

    public init(id: Int64, downloadID: Int64, format: ExportFormat, outWkid: Int, outputPath: String,
                outputSHA256: String? = nil, bytes: Int64? = nil, featureCount: Int64? = nil, createdAt: Date = Date()) {
        self.id = id
        self.downloadID = downloadID
        self.format = format
        self.outWkid = outWkid
        self.outputPath = outputPath
        self.outputSHA256 = outputSHA256
        self.bytes = bytes
        self.featureCount = featureCount
        self.createdAt = createdAt
    }
}

extension AppDatabase {
    private static let exportColumns = "id, download_id, format, out_wkid, output_path, output_sha256, bytes, feature_count, created_at"

    /// Records a re-export. A previous record for the same output path is replaced: the file was.
    @discardableResult
    public func recordExport(downloadID: Int64, format: ExportFormat, outWkid: Int, result: ExportResult,
                             at date: Date = Date()) throws -> ExportRecord {
        try query("DELETE FROM export WHERE output_path = ?;", [.string(result.path)])
        let id = try query("""
            INSERT INTO export (download_id, format, out_wkid, output_path, output_sha256, bytes, feature_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING id;
            """, [.int(downloadID), .string(format.rawValue), .int(Int64(outWkid)), .string(result.path), .string(result.sha256),
                  .int(result.bytes), .int(result.featureCount), date.bindValue]).rows.first?.first?.int64
        guard let id else { throw MetadataStoreError.unexpectedRow("export insert") }
        return ExportRecord(id: id, downloadID: downloadID, format: format, outWkid: outWkid, outputPath: result.path,
                            outputSHA256: result.sha256, bytes: result.bytes, featureCount: result.featureCount, createdAt: date)
    }

    /// Re-exports of one download, newest first.
    public func exports(downloadID: Int64) throws -> [ExportRecord] {
        try query("SELECT \(Self.exportColumns) FROM export WHERE download_id = ? ORDER BY created_at DESC, id DESC;",
                  [.int(downloadID)]).rows.compactMap(Self.exportRecord)
    }

    /// Re-exports of every download of a layer, newest first.
    public func exports(layerID: Int64) throws -> [ExportRecord] {
        try query("""
            SELECT \(Self.exportColumns) FROM export
            WHERE download_id IN (SELECT id FROM download WHERE layer_id = ?) ORDER BY created_at DESC, id DESC;
            """, [.int(layerID)]).rows.compactMap(Self.exportRecord)
    }

    public func deleteExport(id: Int64) throws {
        try query("DELETE FROM export WHERE id = ?;", [.int(id)])
    }

    private static func exportRecord(_ r: [SQLValue]) -> ExportRecord? {
        guard r.count == 9, let id = r[0].int64, let downloadID = r[1].int64,
              let format = r[2].stringValue.flatMap(ExportFormat.init(rawValue:)), let wkid = r[3].intValue,
              let path = r[4].stringValue, let created = r[8].dateFromMicros else { return nil }
        return ExportRecord(id: id, downloadID: downloadID, format: format, outWkid: wkid, outputPath: path,
                            outputSHA256: r[5].stringValue, bytes: r[6].int64, featureCount: r[7].int64, createdAt: created)
    }
}

extension AppDatabase {
    /// Runs still marked running belong to a process that is gone (quit, crash): park them as
    /// paused so they can be resumed. Call once at launch, before anything starts.
    @discardableResult
    public func markInterruptedDownloads() throws -> Int {
        try query("UPDATE download SET status = 'paused', error = ? WHERE status = 'running';",
                  [.string("Interrupted when the app quit; resume to continue.")])
        return try query("SELECT changes();").rows.first?.first?.intValue ?? 0
    }
}
