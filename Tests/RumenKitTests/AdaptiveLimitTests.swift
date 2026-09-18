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

    private func sample(work: Double, seconds: Double, budget: Double = 100, at: Int? = nil) -> AdaptiveLimit.Sample {
        AdaptiveLimit.Sample(work: work, elapsed: seconds, budget: budget, at: at)
    }

    /// A verdict needs `verdictSamples` responses at the new value; feeding one and reading the
    /// answer is what the tests used to do, and what the server used to get away with.
    private func settle(_ limit: inout AdaptiveLimit, work: Double, seconds: Double, budget: Double = 100, at: Int? = nil) {
        for _ in 0..<2 { limit.succeeded(sample(work: work, seconds: seconds, budget: budget, at: at)) }
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

    /// Cornwall's planning polygons take about thirty seconds before the first byte whatever page
    /// size is asked for: the cost is fixed per request and the payload nearly free. Asking for
    /// 100 instead of 2,000 therefore costs twenty times the total time for the same data, so the
    /// limit must climb.
    ///
    /// An earlier rule held the climb past half the budget and stopped it dead here, because the
    /// budget shrinks with the page size while this server's latency does not — 30s of a 100-row
    /// budget reads as half spent, the same 30s of a 2,000-row budget as a fifth.
    func testAFixedPerRequestCostStillClimbsToTheCeiling() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        for _ in 0..<20 {
            let budget = ArcGISClient.timeout(forFeatures: limit.value)
            limit.succeeded(sample(work: Double(limit.value), seconds: 30, budget: budget, at: limit.value))
        }
        XCTAssertEqual(limit.value, 2_000, "a fixed cost per request means asking for as much as possible")
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
    /// see. The step is given back, and the value is left alone for a good while afterwards.
    func testAStepThatCarriesLessPerSecondIsGivenBack() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 1))      // 100/s at 100
        XCTAssertEqual(limit.value, 200)

        settle(&limit, work: 200, seconds: 8)               // 25/s at 200: worse, twice over
        XCTAssertEqual(limit.value, 100, "back to the size that was actually faster")
        XCTAssertEqual(limit.unprofitable, 200)

        for _ in 0..<20 { limit.succeeded(sample(work: 100, seconds: 1)) }
        XCTAssertEqual(limit.value, 100, "and it does not creep straight back up to it")
    }

    /// A verdict is a measurement, not a life sentence: after enough has gone right at the value
    /// beneath it, the step is tried once more. MidKent's planning polygons are why — one
    /// verdict in the first second held the page size at 100 for 843 requests, each paying a
    /// seek that a page of 2,000 would have paid once.
    func testAnUnprofitableVerdictIsTriedAgain() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 1))
        settle(&limit, work: 200, seconds: 8)
        XCTAssertEqual(limit.unprofitable, 200)

        for _ in 0..<AdaptiveLimit.retryUnprofitableAfter { limit.succeeded(sample(work: 100, seconds: 1)) }
        XCTAssertNil(limit.unprofitable, "the cap is let go of once it has held long enough")
        limit.succeeded(sample(work: 100, seconds: 1))
        XCTAssertEqual(limit.value, 200, "and the step is tried again")
    }

    func testAStepThatPaysIsKept() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 1))      // 100/s
        XCTAssertEqual(limit.value, 200)

        settle(&limit, work: 200, seconds: 1)               // 200/s: better
        XCTAssertEqual(limit.value, 400, "worth it, so carry on climbing")
        XCTAssertNil(limit.unprofitable)
    }

    /// The bar allows a few per cent, so ordinary variation between responses does not undo a
    /// good size. A real collapse still does — see the test above, where throughput falls to a
    /// quarter and the step is given straight back.
    func testAModestDipDoesNotGiveBackAGoodStep() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 1))      // 100/s
        settle(&limit, work: 200, seconds: 1)               // 200/s; climbs to 400
        XCTAssertEqual(limit.value, 400)

        settle(&limit, work: 400, seconds: 2.1)             // ~190/s: a few per cent off, not a collapse
        XCTAssertNil(limit.unprofitable, "ordinary variation is not a verdict")
        XCTAssertEqual(limit.value, 800, "still worth climbing")
    }

    // MARK: - A response speaks only for the value it was sent at

    /// With several requests in flight, the response that lands after a step usually left before
    /// it. Judging the step by that response means judging a change on evidence gathered before
    /// it was made — which is how a page size gets condemned for a slowness it had nothing to do
    /// with, and how a concurrency step gets waved through by a request that never felt it.
    func testAResponseFromBeforeTheStepIsNotEvidence() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        limit.succeeded(sample(work: 100, seconds: 1, at: 100))
        XCTAssertEqual(limit.value, 200)

        // Two stragglers issued at 100, both dreadful. They say nothing about 200.
        limit.succeeded(sample(work: 100, seconds: 20, at: 100))
        limit.succeeded(sample(work: 100, seconds: 20, at: 100))
        XCTAssertEqual(limit.value, 200, "a response sent at 100 cannot condemn 200")
        XCTAssertNil(limit.unprofitable)

        settle(&limit, work: 200, seconds: 1, at: 200)
        XCTAssertEqual(limit.value, 400, "and the value it was sent at is heard")
    }

    /// The run that prompted all this: MidKent's WFS, where every request pays a seek that grows
    /// with the offset, several are in flight, and the page itself is nearly free. Latency rises
    /// through the run no matter what the page size does. The limit must still climb, because a
    /// bigger page is how the seek gets paid fewer times.
    func testARisingBaselineWithRequestsInFlightStillClimbs() {
        var limit = AdaptiveLimit.pageSize(ceiling: 2_000)
        var offset = 0.0
        var inFlight = [100, 100, 100]      // three requests already on their way
        for _ in 0..<80 {
            inFlight.append(limit.value)
            let landed = inFlight.removeFirst()      // what arrives now left three requests ago
            offset += Double(landed)
            // Seek cost grows with the offset; the features themselves are nearly free. These are
            // MidKent's own numbers: at row 140,000, 100 features cost 8.3s and 5,000 cost 12.0s.
            let elapsed = 0.5 + offset * 0.00006 + Double(landed) * 0.0007
            limit.succeeded(sample(work: Double(landed), seconds: elapsed, budget: 120, at: landed))
        }
        XCTAssertEqual(limit.value, 2_000, "a nearly free page against a fixed seek means ask for everything")
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
