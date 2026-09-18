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

    public init(floor: Int, ceiling: Int, step: Int = 1, cadence: Cadence = .perResponse) {
        self.floor = max(1, floor)
        self.ceiling = max(1, ceiling)
        self.step = max(1, step)
        self.cadence = cadence
        // A ceiling below the floor wins: a server that will only give 50 gets asked for 50.
        self.value = min(self.floor, self.ceiling)
    }

    /// A clean response: climb, doubling while probing and stepping afterwards.
    public mutating func succeeded() {
        guard value < ceiling else {
            successes = 0
            return
        }
        successes += 1
        if isProbing {
            value = clamp(value * 2)
            successes = 0
            return
        }
        let needed = cadence == .perRound ? max(1, value) : 1
        if successes >= needed {
            value = clamp(value + step)
            successes = 0
        }
    }

    /// The server pushed back: halve, and leave the doubling phase for good.
    public mutating func pushedBack() {
        isProbing = false
        successes = 0
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

    /// Holds a value inside `floor...ceiling`, rounded down to a whole `step`. The ceiling
    /// itself is always reachable, even when it is not a multiple of the step — the server
    /// named that number, so it is worth asking for.
    private func clamp(_ proposed: Int) -> Int {
        if proposed >= ceiling { return ceiling }
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
