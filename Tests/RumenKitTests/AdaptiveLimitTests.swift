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

    // MARK: - Not walking back into the cliff

    private func sample(work: Double, seconds: Double, budget: Double = 100) -> AdaptiveLimit.Sample {
        AdaptiveLimit.Sample(work: work, elapsed: seconds, budget: budget)
    }

    /// The flaw in judging purely by "did it work": after a backoff the limit climbed one step
    /// per success, straight back into the value that had just cost a timeout, and round again.
    /// A refused value is remembered and the climb stops beneath it.
    func testTheClimbNeverReturnsToAValueThatFailed() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        for _ in 0..<5 { limit.succeeded() }
        XCTAssertEqual(limit.value, 2_000)

        limit.pushedBack()
        XCTAssertEqual(limit.value, 1_000)
        XCTAssertEqual(limit.knownBad, 2_000)

        // Far more successes than it would take to creep back to 2,000.
        for _ in 0..<100 { limit.succeeded() }
        XCTAssertEqual(limit.value, 1_900, "it climbs to just below what failed, and stops")
        XCTAssertEqual(limit.effectiveCeiling, 1_900)
    }

    func testRepeatedRefusalsLowerTheCeilingEachTime() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        for _ in 0..<5 { limit.succeeded() }
        limit.pushedBack()                      // 2,000 bad, now 1,000
        for _ in 0..<100 { limit.succeeded() }
        XCTAssertEqual(limit.value, 1_900)

        limit.pushedBack()                      // 1,900 bad, now 900
        XCTAssertEqual(limit.knownBad, 1_900)
        for _ in 0..<100 { limit.succeeded() }
        XCTAssertEqual(limit.value, 1_800, "the ceiling ratchets down, never back up")
    }

    // MARK: - Backing off on time rather than on failure

    /// Past half the time budget the climb stops: the next size up would likely go over, and
    /// going over costs a full timeout and a re-plan.
    func testARequestNearItsTimeBudgetHoldsTheClimb() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 60))     // 60% of budget
        XCTAssertEqual(limit.value, 100, "no climb this close to the edge")
        XCTAssertFalse(limit.isProbing, "and the doubling phase is over")
    }

    /// Past three-quarters it gives ground without waiting to be refused.
    func testARequestVeryNearItsBudgetStepsDown() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        for _ in 0..<3 { limit.succeeded() }
        XCTAssertEqual(limit.value, 800)

        limit.succeeded(sample(work: 800, seconds: 80))     // 80% of budget
        XCTAssertEqual(limit.value, 700, "retreat before the cliff, not after it")
        XCTAssertNil(limit.knownBad, "nothing was refused, so nothing is known bad")
    }

    func testAComfortableRequestStillClimbs() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 10))     // 10% of budget
        XCTAssertEqual(limit.value, 200)
    }

    // MARK: - A step has to pay for itself

    /// A bigger page that succeeds can still carry less per second, which "did it work" cannot
    /// see. The step is given back and not tried again.
    func testAStepThatCarriesLessPerSecondIsGivenBack() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 1))      // 100/s at 100
        XCTAssertEqual(limit.value, 200)

        limit.succeeded(sample(work: 200, seconds: 8))      // 25/s at 200: worse
        XCTAssertEqual(limit.value, 100, "back to the size that was actually faster")
        XCTAssertEqual(limit.unprofitable, 200)

        for _ in 0..<50 { limit.succeeded(sample(work: 100, seconds: 1)) }
        XCTAssertEqual(limit.value, 100, "and it does not creep back up to it")
    }

    func testAStepThatPaysIsKept() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 1))      // 100/s
        XCTAssertEqual(limit.value, 200)

        limit.succeeded(sample(work: 200, seconds: 1))      // 200/s: better
        XCTAssertEqual(limit.value, 400, "worth it, so carry on climbing")
        XCTAssertNil(limit.unprofitable)
    }

    /// Throughput is smoothed and the bar allows a few per cent, so ordinary variation between
    /// responses does not undo a good size. A real collapse still does — see the test above,
    /// where throughput halves and the step is given straight back.
    func testAModestDipDoesNotGiveBackAGoodStep() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 1))      // 100/s
        limit.succeeded(sample(work: 200, seconds: 1))      // 200/s, so 150/s smoothed; climbs to 400
        XCTAssertEqual(limit.value, 400)

        limit.succeeded(sample(work: 400, seconds: 2.8))    // ~143/s: a few per cent off, not a collapse
        XCTAssertNil(limit.unprofitable, "ordinary variation is not a verdict")
        XCTAssertEqual(limit.value, 800, "still worth climbing")
    }

    /// A fast server answers in milliseconds, where the measurement is mostly jitter. Dividing
    /// by it would have good page sizes thrown away over noise, so such a response counts as a
    /// success and says nothing about throughput.
    func testResponsesTooQuickToMeasureDoNotDecideAnything() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 0.004))
        XCTAssertEqual(limit.value, 200, "still a success, so still a climb")

        // A wildly different apparent throughput, at a duration too short to mean anything.
        limit.succeeded(sample(work: 200, seconds: 0.03))
        XCTAssertNil(limit.unprofitable, "no verdict from an unmeasurable pair")
        XCTAssertEqual(limit.value, 400)
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
