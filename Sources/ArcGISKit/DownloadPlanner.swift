import Foundation

/// The user's choices for a download (the Download tab).
public struct DownloadRequest: Sendable, Equatable {
    public var layerID: Int64
    public var whereClause: String = "1=1"
    public var outWkid: Int = 4326
    public var format: ExportFormat = .geoParquet
    public var domainLabels: Bool = false
    /// Base directory; the file lands at `<dir>/<server>/<service>/<layer>.<ext>`.
    public var outputDirectory: URL
    /// Replace an existing output file. The engine refuses without it (SPEC §5.7).
    public var overwrite: Bool = false
    /// Manual strategy override, offered only once automatic selection has failed.
    public var manualStrategy: Assessment.Strategy? = nil
    public var manualPageSize: Int? = nil

    public init(layerID: Int64, outputDirectory: URL) {
        self.layerID = layerID
        self.outputDirectory = outputDirectory
    }
}

/// Chunk maths for the three automatic strategies (SPEC §5.6). Pure; the engine fetches the
/// count, statistics, or id list it needs and calls these.
public enum DownloadPlanner {
    /// Offset paging: one chunk per page up to `count` (at least one, so an empty layer still
    /// makes one request and records zero features).
    public static func offsetChunks(downloadID: Int64, count: Int64, pageSize: Int) -> [DownloadChunk] {
        let size = Int64(max(1, pageSize))
        let pages = max(1, Int((count + size - 1) / size))
        return (0..<pages).map { i in
            DownloadChunk(downloadID: downloadID, seq: i, kind: .offset, offset: Int64(i) * size)
        }
    }

    /// OID range windows of `pageSize` ids each across `[minOID, maxOID]`.
    public static func rangeChunks(downloadID: Int64, minOID: Int64, maxOID: Int64, pageSize: Int) -> [DownloadChunk] {
        guard maxOID >= minOID else { return [] }
        let size = Int64(max(1, pageSize))
        var chunks = [DownloadChunk]()
        var lo = minOID
        while lo <= maxOID {
            let hi = min(maxOID, lo + size - 1)
            chunks.append(DownloadChunk(downloadID: downloadID, seq: chunks.count, kind: .oidRange, lo: lo, hi: hi))
            lo = hi + 1
        }
        return chunks
    }

    /// Batches of `pageSize` ids, in ascending id order.
    public static func listChunks(downloadID: Int64, objectIDs: [Int64], pageSize: Int) -> [DownloadChunk] {
        let ids = objectIDs.sorted()
        let size = max(1, pageSize)
        return stride(from: 0, to: ids.count, by: size).enumerated().map { seq, start in
            DownloadChunk(downloadID: downloadID, seq: seq, kind: .oidList,
                          lo: ids[start], hi: ids[min(start + size, ids.count) - 1], objectIDs: Array(ids[start..<min(start + size, ids.count)]))
        }
    }

    /// The `query` options for one chunk.
    public static func options(for chunk: DownloadChunk, whereClause: String, outWkid: Int, oidField: String, pageSize: Int,
                               canOrderBy: Bool) -> QueryOptions {
        var options = QueryOptions(whereClause: whereClause, outFields: nil, returnGeometry: true, outWkid: outWkid)
        switch chunk.kind {
        case .offset:
            options.offset = chunk.offset.map(Int.init)
            options.count = pageSize
            if canOrderBy { options.orderBy = (oidField, true) }
        case .oidRange:
            let base = whereClause.trimmingCharacters(in: .whitespacesAndNewlines)
            let clause = "\(oidField) >= \(chunk.lo ?? 0) AND \(oidField) <= \(chunk.hi ?? 0)"
            options.whereClause = base.isEmpty || base == "1=1" ? clause : "(\(base)) AND \(clause)"
        case .oidList:
            options.objectIDs = chunk.objectIDs ?? []
        }
        return options
    }

    /// The OID-list id fetch is capped (decision 14): beyond it the run pauses and asks for a
    /// manual partitioning where clause.
    public static let objectIDListCap = 5_000_000
}
