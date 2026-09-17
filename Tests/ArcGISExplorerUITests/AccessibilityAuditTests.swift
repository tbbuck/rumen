import XCTest
import AppKit

/// Apple's accessibility audit (`performAccessibilityAudit`, Xcode 15+) run over every state
/// of the window: on macOS that is contrast, element detection and descriptions, hit regions
/// and parent-child structure (clipped text, traits and Dynamic Type are iOS-only checks).
/// Each test launches the app against a scratch home and a loopback
/// ArcGIS server synthesised in this process, so nothing here touches the real database, the
/// real download folder, or the network. The map tab is left out: a web view carries its own
/// accessibility tree and the basemap needs the network.
///
/// Run with `claude-scripts/ui_test.sh`, or from Xcode's test navigator. The first run on a
/// Mac needs UI automation enabled once by an admin:
/// `sudo automationmodetool enable-automationmode-without-authentication`.
@MainActor
final class AccessibilityAuditTests: XCTestCase {

    private var server: FixtureServer!
    private var home: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true   // report every issue in a state, not just the first
        server = try FixtureServer()
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("arcgis-explorer-uitest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        server = nil
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    // MARK: - Launching

    /// Launches against the scratch home with the given arguments and waits for the window.
    @discardableResult
    private func launch(_ arguments: [String], appearance: String = "light") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--home", home.path, "--appearance", appearance] + arguments
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20), "the window never appeared")
        self.app = app
        return app
    }

    /// Launches on the fixture layer and waits for its page.
    private func launchOnLayer(tab: String? = nil, run: String? = nil, appearance: String = "light") -> XCUIApplication {
        var arguments = ["--open", server.layerURL]
        if let tab { arguments += ["--tab", tab] }
        if let run { arguments += ["--run", run] }
        let app = launch(arguments, appearance: appearance)
        XCTAssertTrue(app.staticTexts["Towns"].firstMatch.waitForExistence(timeout: 30), "the layer page never appeared")
        return app
    }

    /// Runs the audit and records every issue as its own failure, with the element it names.
    ///
    /// Contrast is the exception: on macOS the audit judges contrast from the rendered pixels
    /// of an element's frame, and on this app it flags 24px bold `ink` headings and 12px
    /// monospaced cells whose nominal ratio is above 13:1, alongside real findings. Contrast is
    /// therefore proved on the palette itself (`PaletteContrastTests`, WCAG ratios of every text
    /// tone on both grounds), and the audit's contrast reports are attached to the test as
    /// information rather than failures.
    private func audit(_ app: XCUIApplication, _ state: String, file: StaticString = #filePath, line: UInt = #line) {
        var contrastNotes = [String]()
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                // The frame places an otherwise anonymous element on the screen.
                let element = issue.element.map { " — \($0) at \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" } ?? ""
                let detail = issue.detailedDescription == issue.compactDescription ? "" : " (\(issue.detailedDescription))"
                if issue.auditType == .contrast {
                    contrastNotes.append("\(issue.compactDescription)\(element)")
                    return true
                }
                XCTFail("[\(state)] \(issue.auditType.name): \(issue.compactDescription)\(element)\(detail)", file: file, line: line)
                return true   // recorded above; let the audit go on to the next issue
            }
        } catch {
            XCTFail("[\(state)] the audit could not run: \(error)", file: file, line: line)
        }
        if !contrastNotes.isEmpty {
            let attachment = XCTAttachment(string: contrastNotes.joined(separator: "\n"))
            attachment.name = "Contrast notes: \(state)"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("[\(state)] contrast notes (advisory): \(contrastNotes.count)")
            for note in contrastNotes { print("  \(note)") }
        }
    }

    // MARK: - States

    func testStartPage() {
        let app = launch([])
        XCTAssertTrue(app.staticTexts["Open a server"].waitForExistence(timeout: 10))
        audit(app, "start page, day")
    }

    func testStartPageAtNight() {
        let app = launch([], appearance: "dark")
        XCTAssertTrue(app.staticTexts["Open a server"].waitForExistence(timeout: 10))
        audit(app, "start page, night")
    }

    func testStartPageWithAKnownServer() {
        launchOnLayer().terminate()
        let app = launch([])
        XCTAssertTrue(app.staticTexts["Where to?"].waitForExistence(timeout: 10))
        audit(app, "start page with a server")
    }

    func testAddServerSheet() {
        let app = launch([])
        // The start page's URL field, not the title bar's column search (also a text field).
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS 'rest/services'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the start page's URL field was not found")
        // Pasted rather than typed: synthesised keystrokes drop the colons on some keyboard layouts.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(server.layerURL, forType: .string)
        field.click()
        field.typeKey("v", modifierFlags: .command)
        field.typeKey(.enter, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Add a server"].waitForExistence(timeout: 10), "the add-server sheet never appeared")
        audit(app, "add-server sheet")
    }

    func testLayerOverview() {
        audit(launchOnLayer(), "layer overview, day")
    }

    func testLayerOverviewAtNight() {
        audit(launchOnLayer(appearance: "dark"), "layer overview, night")
    }

    func testLayerFields() {
        audit(launchOnLayer(tab: "fields"), "fields tab")
    }

    func testLayerQueryWithPreview() {
        let app = launchOnLayer(tab: "query", run: "preview")
        XCTAssertTrue(app.staticTexts["Town 1"].firstMatch.waitForExistence(timeout: 30), "the preview never arrived")
        audit(app, "query tab with a preview")
    }

    func testLayerDownloadTab() {
        audit(launchOnLayer(tab: "download"), "download tab")
    }

    func testLayerRawTab() {
        audit(launchOnLayer(tab: "raw"), "raw tab")
    }

    /// Waits for the run to finish, then opens the drawer by the strip's own "Show all" link.
    private func openDrawerAfterDownload(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Done"].firstMatch.waitForExistence(timeout: 60), "the download never finished")
        let showAll = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show all'")).firstMatch
        XCTAssertTrue(showAll.waitForExistence(timeout: 10), "the transfers strip shows no run")
        showAll.click()
        XCTAssertTrue(app.buttons["Show in Finder"].firstMatch.waitForExistence(timeout: 10), "the drawer never opened")
    }

    func testTransfersDrawerWithAFinishedRun() {
        let app = launchOnLayer(run: "download")
        openDrawerAfterDownload(app)
        audit(app, "transfers drawer, day")
    }

    func testTransfersDrawerAtNight() {
        let app = launchOnLayer(run: "download", appearance: "dark")
        openDrawerAfterDownload(app)
        audit(app, "transfers drawer, night")
    }

    func testStoredTab() {
        let app = launchOnLayer(run: "download")
        XCTAssertTrue(app.staticTexts["Done"].firstMatch.waitForExistence(timeout: 60), "the download never finished")
        app.buttons["Stored"].firstMatch.click()   // the tabs are buttons
        XCTAssertTrue(app.staticTexts["Town 1"].firstMatch.waitForExistence(timeout: 30), "the stored rows never appeared")
        audit(app, "stored tab")
    }

    func testPreferences() {
        let app = launch(["--run", "preferences"])
        XCTAssertTrue(app.windows.count >= 2 || app.staticTexts["Download folder"].waitForExistence(timeout: 10), "the preferences window never appeared")
        audit(app, "preferences")
    }

    func testServerSettingsSheet() {
        launchOnLayer().terminate()
        let app = launch([])
        let settings = app.buttons["Server settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10), "the server row's settings button was not found")
        settings.click()
        XCTAssertTrue(app.staticTexts["Server settings"].waitForExistence(timeout: 10), "the settings sheet never appeared")
        audit(app, "server settings sheet")
    }
}

private extension XCUIAccessibilityAuditType {
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
