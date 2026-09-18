import XCTest
import RumenKit

final class ChunkFeedTests: XCTestCase {

    /// Drains a feed at a fixed size, as a run with a settled page size would.
    private func drain(_ feed: inout ChunkFeed, size: Int, from seq: Int = 0) -> [DownloadChunk] {
        var chunks = [DownloadChunk]()
        while let chunk = feed.next(downloadID: 1, seq: seq + chunks.count, size: size) { chunks.append(chunk) }
        return chunks
    }

    // MARK: - Offset

    func testOffsetCoversEveryFeatureExactlyOnce() {
        var feed = ChunkFeed(work: .offset(count: 2_500))
        let chunks = drain(&feed, size: 1_000)
        XCTAssertEqual(chunks.map(\.offset), [0, 1_000, 2_000])
        XCTAssertEqual(chunks.map(\.limit), [1_000, 1_000, 500], "the last page is short, not over-long")
        XCTAssertTrue(feed.isExhausted)
    }

    /// The point of the whole exercise: the size may change between chunks, and the coverage
    /// must still be contiguous and complete.
    func testAGrowingPageSizeStillTilesTheWork() {
        var feed = ChunkFeed(work: .offset(count: 1_000))
        var chunks = [DownloadChunk]()
        for size in [100, 200, 400, 800] {
            guard let chunk = feed.next(downloadID: 1, seq: chunks.count, size: size) else { break }
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks.map(\.offset), [0, 100, 300, 700])
        XCTAssertEqual(chunks.map(\.limit), [100, 200, 400, 300])
        XCTAssertTrue(feed.isExhausted)

        // Contiguous from zero, no gaps and no overlaps.
        var expected: Int64 = 0
        for chunk in chunks {
            XCTAssertEqual(chunk.offset, expected)
            expected += Int64(chunk.limit ?? 0)
        }
        XCTAssertEqual(expected, 1_000)
    }

    func testAnEmptyLayerYieldsNothing() {
        var feed = ChunkFeed(work: .offset(count: 0))
        XCTAssertTrue(feed.isExhausted)
        XCTAssertNil(feed.next(downloadID: 1, seq: 0, size: 100))
    }

    // MARK: - Resuming

    func testOffsetResumesAfterWhatWasRecorded() {
        let done = [DownloadChunk(downloadID: 1, seq: 0, kind: .offset, offset: 0, limit: 100, status: .done),
                    DownloadChunk(downloadID: 1, seq: 1, kind: .offset, offset: 100, limit: 200, status: .done)]
        var feed = ChunkFeed(work: .offset(count: 1_000), after: done)
        XCTAssertEqual(feed.cursor, 300)
        let next = feed.next(downloadID: 1, seq: 2, size: 400)
        XCTAssertEqual(next?.offset, 300)
        XCTAssertEqual(next?.limit, 400)
    }

    /// A chunk the server refused is recorded as `split` and replaced by its halves. Counting it
    /// as well as its halves would leave a hole in the plan.
    func testASplitParentDoesNotAdvanceTheCursor() {
        let chunks = [DownloadChunk(downloadID: 1, seq: 0, kind: .offset, offset: 0, limit: 800, status: .split),
                      DownloadChunk(downloadID: 1, seq: 1, kind: .offset, offset: 0, limit: 400, status: .done),
                      DownloadChunk(downloadID: 1, seq: 2, kind: .offset, offset: 400, limit: 400, status: .pending)]
        let feed = ChunkFeed(work: .offset(count: 2_000), after: chunks)
        XCTAssertEqual(feed.cursor, 800, "the halves cover the parent's range, and no more")
    }

    /// A pending chunk counts as planned: resuming must not hand the same offset out twice.
    func testPendingChunksStillAdvanceTheCursor() {
        let chunks = [DownloadChunk(downloadID: 1, seq: 0, kind: .offset, offset: 0, limit: 500, status: .done),
                      DownloadChunk(downloadID: 1, seq: 1, kind: .offset, offset: 500, limit: 500, status: .pending)]
        let feed = ChunkFeed(work: .offset(count: 2_000), after: chunks)
        XCTAssertEqual(feed.cursor, 1_000)
    }

    // MARK: - OID ranges

    func testOIDRangeWindowsAreInclusiveAndContiguous() {
        var feed = ChunkFeed(work: .oidRange(min: 10, max: 34))
        let chunks = drain(&feed, size: 10)
        XCTAssertEqual(chunks.map(\.lo), [10, 20, 30])
        XCTAssertEqual(chunks.map(\.hi), [19, 29, 34])
        XCTAssertTrue(feed.isExhausted)
    }

    func testOIDRangeResumesAfterTheHighestWindow() {
        let done = [DownloadChunk(downloadID: 1, seq: 0, kind: .oidRange, lo: 10, hi: 19, status: .done)]
        let feed = ChunkFeed(work: .oidRange(min: 10, max: 100), after: done)
        XCTAssertEqual(feed.cursor, 20)
    }

    func testASingleOIDRange() {
        var feed = ChunkFeed(work: .oidRange(min: 5, max: 5))
        let chunks = drain(&feed, size: 100)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?.lo, 5)
        XCTAssertEqual(chunks.first?.hi, 5)
    }

    // MARK: - OID lists

    func testOIDListBatchesInOrder() {
        var feed = ChunkFeed(work: .oidList([1, 2, 3, 4, 5, 6, 7]))
        let chunks = drain(&feed, size: 3)
        XCTAssertEqual(chunks.map { $0.objectIDs ?? [] }, [[1, 2, 3], [4, 5, 6], [7]])
        XCTAssertTrue(feed.isExhausted)
    }

    func testOIDListResumesByIdNotByCount() {
        let ids: [Int64] = [10, 20, 30, 40, 50, 60]
        let done = [DownloadChunk(downloadID: 1, seq: 0, kind: .oidList, lo: 10, hi: 30,
                                  objectIDs: [10, 20, 30], status: .done)]
        var feed = ChunkFeed(work: .oidList(ids), after: done)
        XCTAssertEqual(feed.cursor, 3)
        let next = feed.next(downloadID: 1, seq: 1, size: 2)
        XCTAssertEqual(next?.objectIDs ?? [], [40, 50])
    }

    // MARK: - Estimating

    func testRemainingRequestsFollowsTheSize() {
        let feed = ChunkFeed(work: .offset(count: 2_000))
        XCTAssertEqual(feed.remainingRequests(at: 100), 20)
        XCTAssertEqual(feed.remainingRequests(at: 2_000), 1)
        XCTAssertEqual(feed.remainingRequests(at: 900), 3, "a part-page still costs a request")
    }

    func testRemainingRequestsIsZeroWhenExhausted() {
        var feed = ChunkFeed(work: .offset(count: 100))
        _ = drain(&feed, size: 100)
        XCTAssertEqual(feed.remainingRequests(at: 100), 0)
    }
}
