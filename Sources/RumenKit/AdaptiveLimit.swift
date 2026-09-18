import Foundation

/// A limit discovered rather than declared: it opens at its floor, climbs while the server
/// keeps up, and halves the moment the server pushes back.
///
/// This app asks a server two questions of the same shape — how many requests will you take at
/// once, and how many features will you give me per request — and neither answer can be trusted
/// from metadata. `maxRecordCount` is what a server claims on a good day; a concurrency
/// preference is what the user hopes for. Both are ceilings, not starting points.
///
/// The asymmetry is what makes probing upward correct. Undershooting costs one extra cheap
/// round trip. Overshooting costs a timeout, its retries, and a re-plan — on a slow server,
/// minutes per request, paid again on every chunk until something learns. So start low, double
/// while it holds (slow start), and on the first refusal halve and creep afterwards, because a
/// box that has said no once will say it again.
///
/// The limit belongs to the host, not the protocol: an ArcGIS service and a WFS behind one
/// underpowered server are one server, and what either learns should spare the other.
public struct AdaptiveLimit: Sendable, Equatable {
    /// How a step is earned once the doubling phase has ended.
    public enum Cadence: Sendable, Equatable {
        /// One step per clean response — for a value measured per request, like a page size.
        case perResponse
        /// One step per full round of clean responses at the current value — for a value that
        /// counts things in flight, where a "round" is every slot reporting back once.
        case perRound
    }

    /// The smallest value worth asking for; below this a refusal is a real error, not size.
    public let floor: Int
    /// The most the server or the user will allow. Never exceeded.
    public private(set) var ceiling: Int
    /// The additive increment after the doubling phase, and the quantum values are rounded to.
    public let step: Int
    public let cadence: Cadence

    public private(set) var value: Int
    /// True until the first pushback: the fast, doubling phase.
    public private(set) var isProbing: Bool = true
    private var successes: Int = 0

    /// The lowest value that has ever been refused. The climb stops below it rather than walking
    /// back into it: without this, "it worked" alone would creep up to the failure point again
    /// after every backoff, so the settled state would be a loop through a timeout.
    public private(set) var knownBad: Int?
    /// The lowest value that worked but carried less through per second than the value below it.
    /// Succeeding is not the same as being worth it.
    public private(set) var unprofitable: Int?
    /// Throughput at the current value, smoothed, so one slow response does not decide anything.
    private var throughput: Double?
    /// Where we climbed from, and what that was worth, so the next samples can judge the step.
    private var previousValue: Int?
    private var throughputBeforeStep: Double?
    /// Responses gathered at the new value since the step, awaiting the verdict.
    private var stepSamples: Int = 0
    private var stepThroughput: Double = 0
    /// Clean responses since arriving at a ceiling that `unprofitable` is holding down.
    private var atCeiling: Int = 0

    public init(floor: Int, ceiling: Int, step: Int = 1, cadence: Cadence = .perResponse) {
        self.floor = max(1, floor)
        self.ceiling = max(1, ceiling)
        self.step = max(1, step)
        self.cadence = cadence
        // A ceiling below the floor wins: a server that will only give 50 gets asked for 50.
        self.value = min(self.floor, self.ceiling)
    }

    /// What one completed request revealed.
    public struct Sample: Sendable, Equatable {
        /// Work carried: features for a page size, one for a request whose size is not measured
        /// in features.
        public let work: Double
        public let elapsed: TimeInterval
        /// The time the request was allowed before it would have been abandoned.
        public let budget: TimeInterval
        /// The value in force when this request *went out*. Responses arrive from requests that
        /// left at several different values — that is what having several in flight means — and
        /// a response that left before the last step knows nothing about it. Nil means the
        /// caller cannot say, and the sample is taken at face value.
        public let at: Int?

        public init(work: Double, elapsed: TimeInterval, budget: TimeInterval, at: Int? = nil) {
            self.work = work
            self.elapsed = elapsed
            self.budget = budget
            self.at = at
        }

        /// Work per second.
        public var throughput: Double { elapsed > 0 ? work / elapsed : .greatestFiniteMagnitude }
        /// How much of the time budget the request used: 1.0 is a request that only just landed.
        public var headroom: Double { budget > 0 ? elapsed / budget : 0 }
    }

    /// Past this share of the time budget, step back down without waiting to be refused. Backing
    /// off on time is the point — a refusal costs a full timeout and a re-plan, a smaller request
    /// costs almost nothing.
    ///
    /// There used to be a second, lower threshold that merely held the climb, and it was wrong.
    /// The budget grows with the page size but many servers' latency does not: Cornwall's
    /// planning polygons take about thirty seconds whatever you ask for, so a 100-record request
    /// reads as having used half its budget while a 2,000-record one reads as a fifth — and the
    /// climb stalled precisely where it mattered most. Whether a bigger page is affordable is
    /// already answered, and answered properly, by whether the last increase improved throughput.
    static let retreatAbove = 0.75
    /// How much worse a step may leave throughput before it counts as not worth keeping.
    ///
    /// Wide on purpose. The two measurements are taken minutes apart, and on many servers the
    /// baseline moves between them — WFS offset paging walks deeper with every request, so a
    /// page of 2,000 is timed against ground that has already got slower than where the page of
    /// 1,600 was timed. At a 5% bar that drift alone condemns every step: MidKent's polygons
    /// went 2,000 → 1,900 → 1,800 → 1,700 and on down to the floor of 100, each value found
    /// "unprofitable" for a slowness the page size had nothing to do with, and the run then paid
    /// 843 seeks instead of 50.
    ///
    /// The asymmetry says how wide. A false condemnation ratchets the value down for the rest of
    /// the run; a false acquittal leaves one page slightly too big, which the time budget and an
    /// outright refusal both still catch. So the bar is set where only a real collapse trips it,
    /// not where drift does.
    static let worthKeeping = 0.75
    /// Requests quicker than this tell us nothing about throughput: at a few milliseconds the
    /// measurement is mostly jitter, and dividing by it would have a fast server throwing away
    /// good page sizes over noise. Such a response still counts as a success.
    static let measurable: TimeInterval = 0.05
    /// Responses at the new value before a step is judged. One is not enough: the first requests
    /// of a run are quick and jittery, and a single unlucky one used to condemn a value for good
    /// — MidKent's planning polygons spent 843 of 922 requests welded to the floor of 100
    /// because of one comparison made in the first second.
    static let verdictSamples = 2
    /// Clean responses at a ceiling held down by `unprofitable` before that verdict is tried
    /// again. A verdict is a measurement, and measurements go stale — an offset walks deeper, a
    /// server warms up, whoever else was hammering it stops. Re-testing costs one request.
    public static let retryUnprofitableAfter = 25

    /// A clean response, with what it revealed. A nil sample means nothing was measured, and the
    /// limit climbs on success alone as it did before.
    public mutating func succeeded(_ sample: Sample? = nil) {
        guard let sample else {
            climb()
            return
        }
        // A response that went out at another value cannot speak for this one, and with several
        // requests in flight most of them did. Judging a step by whichever response lands next
        // means judging it on evidence gathered before it was made: at best the step is waved
        // through, at worst it is condemned for something it did not do.
        if let at = sample.at, at != value { return }

        guard sample.elapsed >= Self.measurable else {
            // Too quick to measure: a success, but no evidence about throughput, so any pending
            // verdict on the last step is abandoned rather than decided on noise.
            forgetPendingStep()
            climb()
            return
        }

        // Did the last step pay? A larger page that succeeds can still be slower overall, which
        // "it worked" can never see. Judged on the mean of the first few responses at the new
        // value, and nothing else moves until it has been judged.
        if let before = throughputBeforeStep, let previous = previousValue {
            stepSamples += 1
            stepThroughput += sample.throughput
            guard stepSamples >= Self.verdictSamples else { return }
            let now = stepThroughput / Double(stepSamples)
            forgetPendingStep()
            throughput = now
            if now < before * Self.worthKeeping {
                unprofitable = value
                atCeiling = 0
                value = clamp(previous)
                successes = 0
                return
            }
        } else {
            // Smoothed, so a single slow response does not overturn a good value.
            throughput = throughput.map { $0 * 0.5 + sample.throughput * 0.5 } ?? sample.throughput
        }

        // Close enough to the time budget to be worth giving ground before being refused.
        if sample.headroom >= Self.retreatAbove {
            isProbing = false
            successes = 0
            value = clamp(value - step)
            return
        }
        climb()
    }

    private mutating func forgetPendingStep() {
        throughputBeforeStep = nil
        previousValue = nil
        stepSamples = 0
        stepThroughput = 0
    }

    private mutating func climb() {
        guard value < effectiveCeiling else {
            successes = 0
            // Sitting at a ceiling that an `unprofitable` verdict is holding down. Once enough
            // has gone right at this value, let the verdict go and try the step again: one
            // request to re-test, against a cap that otherwise lasts the whole run.
            if unprofitable != nil {
                atCeiling += 1
                if atCeiling >= Self.retryUnprofitableAfter {
                    atCeiling = 0
                    unprofitable = nil
                }
            }
            return
        }
        successes += 1
        let target: Int
        if isProbing {
            target = clamp(value * 2)
        } else {
            let needed = cadence == .perRound ? max(1, value) : 1
            guard successes >= needed else { return }
            target = clamp(value + step)
        }
        successes = 0
        guard target != value else { return }
        // Remember what we are leaving, so the next sample can say whether it was worth it.
        previousValue = value
        throughputBeforeStep = throughput
        value = target
    }

    /// The server refused: halve, remember the value as bad, and leave the doubling phase.
    public mutating func pushedBack() {
        knownBad = knownBad.map { Swift.min($0, value) } ?? value
        isProbing = false
        successes = 0
        forgetPendingStep()
        throughput = nil
        value = clamp(value / 2)
    }

    /// Raises or lowers the ceiling, bringing the value down with it when it no longer fits.
    public mutating func setCeiling(_ newCeiling: Int) {
        ceiling = max(1, newCeiling)
        if value > ceiling { value = ceiling }
        if value < floor { value = min(floor, ceiling) }
        successes = 0
    }

    /// Takes up a value a previous run learned, clamped to the ceiling. The doubling phase is
    /// over: a remembered value is already the product of one, and re-probing from the floor
    /// would throw away exactly what was worth keeping.
    public mutating func adopt(_ remembered: Int) {
        value = clamp(remembered)
        isProbing = false
        successes = 0
    }

    /// The highest value still worth trying: the advertised ceiling, held under anything that
    /// has been refused or has proved slower than the value beneath it.
    public var effectiveCeiling: Int {
        var limit = ceiling
        if let knownBad { limit = Swift.min(limit, knownBad - step) }
        if let unprofitable { limit = Swift.min(limit, unprofitable - step) }
        return Swift.max(Swift.min(floor, ceiling), limit)
    }

    /// Holds a value inside `floor...effectiveCeiling`, rounded down to a whole `step`. The
    /// ceiling itself is always reachable, even when it is not a multiple of the step — the
    /// server named that number, so it is worth asking for.
    private func clamp(_ proposed: Int) -> Int {
        let top = effectiveCeiling
        if proposed >= top { return top }
        let rounded = step > 1 ? (proposed / step) * step : proposed
        return max(min(floor, ceiling), rounded)
    }
}

public extension AdaptiveLimit {
    /// How many features to ask for in one request, against a server-advertised ceiling.
    /// Hundreds, because a page size in the tens is noise and one in the thousands is a lie.
    static func pageSize(ceiling: Int) -> AdaptiveLimit {
        AdaptiveLimit(floor: 100, ceiling: ceiling, step: 100, cadence: .perResponse)
    }

    /// How many requests to have in flight against one host, against the user's preference.
    static func concurrency(ceiling: Int) -> AdaptiveLimit {
        AdaptiveLimit(floor: 1, ceiling: ceiling, step: 1, cadence: .perRound)
    }
}
