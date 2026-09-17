import XCTest

/// The same audit run over Apple's own SwiftUI apps, as a reference: a finding that appears
/// on Weather and Font Book as well is the framework's, and one that does not is ours to fix.
/// Every issue is printed with its element and frame, and nothing here fails; the run is a
/// reading, not a verdict. Off by default (it opens other apps and needs them on the Mac):
/// set `REFERENCE_AUDIT=1` in the runner's environment (`TEST_RUNNER_REFERENCE_AUDIT=1` for
/// xcodebuild) to run it.
@MainActor
final class ReferenceAuditTests: XCTestCase {

    private var app: XCUIApplication?

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["REFERENCE_AUDIT"] == "1" else {
            throw XCTSkip("reference audit runs only with REFERENCE_AUDIT=1")
        }
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testWeather() { read("com.apple.weather", "Weather") }
    func testFontBook() { read("com.apple.FontBook", "Font Book") }
    func testFreeform() { read("com.apple.freeform", "Freeform") }
    func testSystemSettings() { read("com.apple.systempreferences", "System Settings") }

    /// A SwiftUI app with one of its own sheets up: the reference for what the audit says of a
    /// sheet SwiftUI presents, which is how this app presents its two.
    func testFontBookWithASheet() {
        read("com.apple.FontBook", "Font Book sheet") { app in
            app.menuBars.menuBarItems["File"].click()
            let item = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH 'New Smart Collection'")).firstMatch
            guard item.waitForExistence(timeout: 5) else { print("[Font Book sheet] no New Smart Collection item"); return }
            item.click()
            _ = app.sheets.firstMatch.waitForExistence(timeout: 10)
            print("[Font Book sheet] sheets up: \(app.sheets.count)")
        }
    }

    /// An AppKit window with a standard save sheet up: the reference for what the audit says
    /// of a window's own buttons and of a sheet, with no SwiftUI in the way.
    func testTextEditWithASaveSheet() {
        read("com.apple.TextEdit", "TextEdit") { app in
            app.typeKey("n", modifierFlags: .command)
            guard app.windows.firstMatch.waitForExistence(timeout: 10) else { return }
            app.typeKey("s", modifierFlags: .command)
            _ = app.sheets.firstMatch.waitForExistence(timeout: 10)
            print("[TextEdit] sheets up: \(app.sheets.count)")
        }
    }

    /// Launches the app, waits for its window, screenshots it, and prints every audit issue.
    private func read(_ bundleID: String, _ name: String, then arrange: ((XCUIApplication) -> Void)? = nil) {
        let app = XCUIApplication(bundleIdentifier: bundleID)
        self.app = app
        app.launch()
        guard app.windows.firstMatch.waitForExistence(timeout: 30) else {
            print("[\(name)] no window appeared"); return
        }
        Thread.sleep(forTimeInterval: 3)
        arrange?(app)
        Thread.sleep(forTimeInterval: 1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "reference: \(name)"
        shot.lifetime = .keepAlways
        add(shot)
        let windows = app.windows.allElementsBoundByIndex.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" }
        print("[\(name)] windows: \(windows)")
        var count = 0
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                count += 1
                let where_ = issue.element.map { " — \($0) at \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" } ?? " — (no element)"
                print("[\(name)] \(issue.auditType.name): \(issue.compactDescription)\(where_)")
                return true
            }
        } catch {
            print("[\(name)] the audit could not run: \(error)")
        }
        print("[\(name)] \(count) issues")
    }
}

private extension XCUIAccessibilityAuditType {  // the option set spelt out, as in AccessibilityAuditTests
    var name: String {
        var names: [String] = []
        if contains(.contrast) { names.append("contrast") }
        if contains(.elementDetection) { names.append("element detection") }
        if contains(.hitRegion) { names.append("hit region") }
        if contains(.sufficientElementDescription) { names.append("element description") }
        if contains(.parentChild) { names.append("parent-child") }
        return names.isEmpty ? "audit" : names.joined(separator: "+")
    }
}
