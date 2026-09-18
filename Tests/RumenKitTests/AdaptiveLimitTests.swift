import XCTest
import RumenKit

final class AdaptiveLimitTests: XCTestCase {

    // MARK: - Slow start

    func testPageSizeOpensAtTheFloorAndDoublesToTheCeiling() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2000)
        XCTAssertEqual(limit.value, 100, "a server's claim is a ceiling, not a starting point")

        let climb = (0..<6).map { _ -> Int in
            limit.succeeded()
            return limit.value
        }
        XCTAssertEqual(climb, [200, 400, 800, 1600, 2000, 2000],
                       "doubling reaches the ceiling in five requests and stops there")
    }

    func testConcurrencyOpensAtOneAndDoubles() {
        var limit = AdaptiveLimit.concurrency(ceiling: 8)
        XCTAssertEqual(limit.value, 1)
        let climb = (0..<5).map { _ -> Int in
            limit.succeeded()
            return limit.value
        }
        XCTAssertEqual(climb, [2, 4, 8, 8, 8])
    }

    // MARK: - Pushback

    func testPushbackHalvesAndEndsProbing() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2000)
        for _ in 0..<5 { limit.succeeded() }
        XCTAssertEqual(limit.value, 2000)
        XCTAssertTrue(limit.isProbing)

        limit.pushedBack()
        XCTAssertEqual(limit.value, 1000)
        XCTAssertFalse(limit.isProbing)

        // No more doubling: the climb back is one step per clean response.
        limit.succeeded()
        XCTAssertEqual(limit.value, 1100)
        limit.succeeded()
        XCTAssertEqual(limit.value, 1200)
    }

    func testRepeatedPushbackStopsAtTheFloor() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2000)
        for _ in 0..<5 { limit.succeeded() }
        for _ in 0..<10 { limit.pushedBack() }
        XCTAssertEqual(limit.value, 100, "never below the floor, however hard the server pushes")
    }

    /// A value counting things in flight earns a step only when every slot has reported back,
    /// otherwise one lucky response would reopen the throttle a server just closed.
    func testConcurrencyStepsPerRoundNotPerResponse() {
        var limit = AdaptiveLimit.concurrency(ceiling: 16)
        for _ in 0..<4 { limit.succeeded() }      // 1 → 2 → 4 → 8 → 16
        XCTAssertEqual(limit.value, 16)
        limit.pushedBack()
        XCTAssertEqual(limit.value, 8)

        for _ in 0..<7 { limit.succeeded() }
        XCTAssertEqual(limit.value, 8, "seven of the eight slots reporting back is not a round")
        limit.succeeded()
        XCTAssertEqual(limit.value, 9, "the eighth completes the round")
    }

    // MARK: - Ceilings and floors

    func testACeilingBelowTheFloorWins() {
        var limit = AdaptiveLimit.pageSize(ceiling: 50)
        XCTAssertEqual(limit.value, 50, "a server that will only give 50 is asked for 50")
        limit.succeeded()
        XCTAssertEqual(limit.value, 50)
        limit.pushedBack()
        XCTAssertEqual(limit.value, 50, "there is nowhere below to go")
    }

    func testAnAwkwardCeilingIsStillReachable() {
        var limit = AdaptiveLimit.pageSize(ceiling: 1234)
        for _ in 0..<5 { limit.succeeded() }
        XCTAssertEqual(limit.value, 1234, "the server named that number, so it is worth asking for")

        limit.pushedBack()
        XCTAssertEqual(limit.value, 600, "but the way back down stays on the hundreds")
    }

    func testLoweringTheCeilingBringsTheValueDown() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2000)
        for _ in 0..<5 { limit.succeeded() }
        XCTAssertEqual(limit.value, 2000)

        limit.setCeiling(500)
        XCTAssertEqual(limit.value, 500)

        limit.setCeiling(4000)
        XCTAssertEqual(limit.value, 500, "a raised ceiling is permission to climb, not a jump")
    }

    // MARK: - Remembering

    func testAdoptingARememberedValueSkipsTheClimb() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2000)
        limit.adopt(800)
        XCTAssertEqual(limit.value, 800)
        XCTAssertFalse(limit.isProbing, "what was learned once is not re-probed")

        limit.succeeded()
        XCTAssertEqual(limit.value, 900, "it creeps from there rather than doubling")
    }

    func testAdoptingRespectsTheCeilingAndTheFloor() {
        var high = AdaptiveLimit.pageSize(ceiling: 1000)
        high.adopt(99_999)
        XCTAssertEqual(high.value, 1000)

        var low = AdaptiveLimit.pageSize(ceiling: 1000)
        low.adopt(3)
        XCTAssertEqual(low.value, 100)
    }
}
