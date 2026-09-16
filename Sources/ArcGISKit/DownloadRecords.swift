import Foundation
import SQLiteKit

/// Export formats. GeoParquet is the default (SPEC §5.7); the rest arrive with M7.
public enum ExportFormat: String, Sendable, CaseIterable, Equatable {
    case geoParquet = "geoparquet"

    public var fileExtension: String {
        switch self { case .geoParquet: "parquet" }
    }
    public var label: String {
        switch self { case .geoParquet: "GeoParquet" }
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
    public var count: Int64?
    public var status: ChunkStatus
    public var attempts: Int
    public var lastError: String?

    public var id: Int { seq }

    public init(downloadID: Int64, seq: Int, kind: Kind, lo: Int64? = nil, hi: Int64? = nil, offset: Int64? = nil,
                objectIDs: [Int64]? = nil, count: Int64? = nil, status: ChunkStatus = .pending, attempts: Int = 0,
                lastError: String? = nil) {
        self.downloadID = downloadID
        self.seq = seq
        self.kind = kind
        self.lo = lo
        self.hi = hi
        self.offset = offset
        self.objectIDs = objectIDs
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
                    INSERT INTO download_chunk (download_id, seq, kind, lo, hi, "offset", object_ids, count, status, attempts, last_error)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                    """, [.int(c.downloadID), .int(Int64(c.seq)), .string(c.kind.rawValue), .optional(c.lo), .optional(c.hi),
                          .optional(c.offset), .optional(c.objectIDs.map { $0.map(String.init).joined(separator: ",") }),
                          .optional(c.count), .string(c.status.rawValue), .int(Int64(c.attempts)), .optional(c.lastError)])
            }
            try execScript("COMMIT;")
        } catch {
            _ = try? execScript("ROLLBACK;")
            throw error
        }
    }

    public func chunks(downloadID: Int64) throws -> [DownloadChunk] {
        try query("""
            SELECT download_id, seq, kind, lo, hi, "offset", object_ids, count, status, attempts, last_error
            FROM download_chunk WHERE download_id = ? ORDER BY seq;
            """, [.int(downloadID)]).rows.map { r in
            DownloadChunk(downloadID: r[0].int64 ?? 0, seq: r[1].intValue ?? 0,
                          kind: r[2].stringValue.flatMap(DownloadChunk.Kind.init(rawValue:)) ?? .offset,
                          lo: r[3].int64, hi: r[4].int64, offset: r[5].int64,
                          objectIDs: r[6].stringValue.map { $0.split(separator: ",").compactMap { Int64($0) } },
                          count: r[7].int64, status: r[8].stringValue.flatMap(ChunkStatus.init(rawValue:)) ?? .pending,
                          attempts: r[9].intValue ?? 0, lastError: r[10].stringValue)
        }
    }

    public func updateChunk(downloadID: Int64, seq: Int, status: ChunkStatus, count: Int64?, attempts: Int, error: String?) throws {
        try query("""
            UPDATE download_chunk SET status = ?, count = ?, attempts = ?, last_error = ? WHERE download_id = ? AND seq = ?;
            """, [.string(status.rawValue), .optional(count), .int(Int64(attempts)), .optional(error), .int(downloadID), .int(Int64(seq))])
    }
}
