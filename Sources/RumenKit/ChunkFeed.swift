import Foundation

/// Hands out a download's chunks as they are needed rather than all at once.
///
/// The plan used to be fixed at the moment a download started, which meant the page size was
/// fixed too: the only way to ask for less was to halve a chunk the server had already refused,
/// and there was no way at all to ask for more. Generating against a cursor lets the page size
/// follow an `AdaptiveLimit` — small while the server is proving itself, larger once it has.
///
/// The cursor is derived from the chunks already recorded, never held only in memory, so a run
/// that resumes after a crash picks up exactly where the last recorded chunk left off. Every
/// strategy covers its work in order and splits only subdivide, so what is covered is always a
/// prefix and the cursor is its high-water mark.
public struct ChunkFeed: Sendable {
    /// The whole of what a download has to fetch.
    public enum Work: Sendable, Equatable {
        /// Offset paging over `count` features.
        case offset(count: Int64)
        /// OID windows across an inclusive range.
        case oidRange(min: Int64, max: Int64)
        /// Explicit ids, ascending.
        case oidList([Int64])
    }

    public let work: Work
    /// How far the plan has reached: the next offset, the next OID, or the next index into the
    /// id list, depending on the strategy.
    public private(set) var cursor: Int64

    /// Resumes the feed behind the chunks already recorded for this run.
    public init(work: Work, after existing: [DownloadChunk] = []) {
        self.work = work
        // A chunk that was split is represented by its halves; counting it as well would skip
        // the range it covers.
        let live = existing.filter { $0.status != .split }
        switch work {
        case .offset:
            cursor = live.compactMap { chunk in
                guard let offset = chunk.offset else { return nil }
                return offset + Int64(chunk.limit ?? 0)
            }.max() ?? 0
        case .oidRange(let min, _):
            cursor = live.compactMap(\.hi).map { $0 + 1 }.max() ?? min
        case .oidList(let ids):
            // Ids are ascending and chunks are contiguous slices of them, so the highest id
            // already covered marks the boundary.
            guard let highest = live.compactMap(\.hi).max() else {
                cursor = 0
                break
            }
            cursor = Int64(ids.partitioningIndex { $0 > highest })
        }
    }

    /// True when every feature is spoken for and `next` has nothing left to give.
    public var isExhausted: Bool {
        switch work {
        case .offset(let count): return cursor >= count
        case .oidRange(_, let max): return cursor > max
        case .oidList(let ids): return cursor >= Int64(ids.count)
        }
    }

    /// The next chunk of up to `size`, or nil once the work is covered. `size` is the run's
    /// current page size, which may differ from the one the previous chunk used.
    public mutating func next(downloadID: Int64, seq: Int, size: Int) -> DownloadChunk? {
        guard !isExhausted else { return nil }
        let size = Int64(Swift.max(1, size))
        switch work {
        case .offset(let count):
            let limit = Swift.min(size, count - cursor)
            let chunk = DownloadChunk(downloadID: downloadID, seq: seq, kind: .offset,
                                      offset: cursor, limit: Int(limit))
            cursor += limit
            return chunk
        case .oidRange(_, let max):
            let hi = Swift.min(max, cursor + size - 1)
            let chunk = DownloadChunk(downloadID: downloadID, seq: seq, kind: .oidRange,
                                      lo: cursor, hi: hi, limit: Int(hi - cursor + 1))
            cursor = hi + 1
            return chunk
        case .oidList(let ids):
            let start = Int(cursor)
            let end = Swift.min(ids.count, start + Int(size))
            let slice = Array(ids[start..<end])
            let chunk = DownloadChunk(downloadID: downloadID, seq: seq, kind: .oidList,
                                      lo: slice.first, hi: slice.last, objectIDs: slice, limit: slice.count)
            cursor = Int64(end)
            return chunk
        }
    }

    /// Roughly how many more requests the rest of the work needs at `size`. The total request
    /// count is genuinely unknown while the page size is still moving, so the transfers UI shows
    /// an estimate that firms up as the size settles.
    public func remainingRequests(at size: Int) -> Int {
        let size = Int64(Swift.max(1, size))
        let left: Int64
        switch work {
        case .offset(let count): left = Swift.max(0, count - cursor)
        case .oidRange(_, let max): left = Swift.max(0, max - cursor + 1)
        case .oidList(let ids): left = Swift.max(0, Int64(ids.count) - cursor)
        }
        return Int((left + size - 1) / size)
    }
}

extension Array where Element: Comparable {
    /// The index of the first element for which `belongsAfter` is true, assuming the array is
    /// sorted so that every such element follows every one that is not. Binary search, because
    /// an OID list runs to millions.
    func partitioningIndex(where belongsAfter: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = low + (high - low) / 2
            if belongsAfter(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}
