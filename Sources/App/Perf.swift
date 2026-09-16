import Foundation
import OSLog

/// Main-thread timing for the unified log (`log show --predicate 'subsystem == "…"'`,
/// category "perf"). Installed only by the `--bench-filter` launch argument.
enum Perf {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ArcGISExplorer", category: "perf")
    nonisolated(unsafe) private static var observer: CFRunLoopObserver?
    nonisolated(unsafe) private static var wokeAt: CFAbsoluteTime = 0
    nonisolated(unsafe) private(set) static var enabled = false

    /// Logs every stretch the main run loop stays busy longer than `threshold` seconds
    /// between two waits: the cost of whatever a keystroke or click set off.
    @MainActor static func installHangObserver(threshold: Double = 0.02) {
        guard observer == nil else { return }
        enabled = true
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let created = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, activities, true, 0) { _, activity in
            let now = CFAbsoluteTimeGetCurrent()
            if activity == .afterWaiting {
                wokeAt = now
            } else if activity == .beforeWaiting, wokeAt > 0 {
                let busy = now - wokeAt
                if busy > threshold { log.notice("main thread busy \(Int(busy * 1000), privacy: .public) ms") }
            }
        }
        observer = created
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
    }

    /// A timing mark; silent unless the observer is installed.
    static func note(_ text: String) {
        guard enabled else { return }
        log.notice("\(text, privacy: .public)")
    }
}
