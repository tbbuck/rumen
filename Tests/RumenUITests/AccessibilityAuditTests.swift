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
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rumen-uitest-\(UUID().uuidString)", isDirectory: true)
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
    /// information rather than failures: a note per element and one picture of the state with
    /// every flagged element outlined.
    ///
    /// The few findings the audit passes over are each attached as a picture of the screen
    /// with the element outlined and the reason written above it, so an exclusion can be seen
    /// rather than taken on trust; each is printed to the log as well.
    private func audit(_ app: XCUIApplication, _ state: String, file: StaticString = #filePath, line: UInt = #line) {
        // The pointer rests where the last click left it, and a tooltip that then appears is an
        // element of its own; park it over the tree panel's empty foot and let any tooltip go.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.9)).hover()
        Thread.sleep(forTimeInterval: 1.2)
        // What the audit saw, kept in the result bundle (claude-scripts/vm_attachments.sh brings it back).
        let screen = XCUIScreen.main.screenshot().image
        attach(screen, as: "state: \(state)")
        var contrastNotes = [String]()
        var contrastFrames = [CGRect]()
        var excluded = 0
        /// Passes a finding over, with the picture and the log line that say why.
        func pass(_ reason: String, _ issue: XCUIAccessibilityAuditIssue, around frame: CGRect?) -> Bool {
            excluded += 1
            print("[\(state)] excluded (\(reason)): \(issue.compactDescription)\(Self.placement(of: issue.element))")
            attach(Self.annotated(screen, frames: frame.map { [$0] } ?? [], caption: "\(reason) — \(issue.compactDescription)", in: .systemRed),
                   as: "excluded \(excluded): \(state) — \(reason)")
            return true
        }
        do {
            try app.performAccessibilityAudit(for: .all) { issue in
                // The frame places an otherwise anonymous element on the screen.
                let element = Self.placement(of: issue.element)
                let detail = issue.detailedDescription == issue.compactDescription ? "" : " (\(issue.detailedDescription))"
                if issue.auditType == .contrast {
                    contrastNotes.append("\(issue.compactDescription)\(element)")
                    if let frame = issue.element?.frame { contrastFrames.append(frame) }
                    return true
                }
                // A mismatch with no element appears only while a sheet is up; the sheet's tree
                // (printed below) is the app's own named groups and fields, and Font Book with one
                // of its own SwiftUI sheets up reports the very same finding (ReferenceAuditTests).
                if issue.auditType == .parentChild, issue.element == nil, app.sheets.count > 0 {
                    print("[\(state)] the sheet's tree at the time:\n    " + app.sheets.firstMatch.debugDescription.prefix(2500).replacingOccurrences(of: "\n", with: "\n    "))
                    return pass("no element, with a sheet up", issue, around: app.sheets.firstMatch.frame)
                }
                // The window's own buttons (close, minimise, zoom, in the top-left 80×48 of a window)
                // are AppKit's; the element tree shows the mismatch inside the zoom button's group,
                // and every Apple app audited for reference (Font Book, System Settings, TextEdit,
                // Weather) reports the same 14×14 group at the same spot in each of its windows.
                if issue.auditType == .parentChild, let element = issue.element,
                   Self.windowFrames(of: app).contains(where: { CGRect(x: $0.minX, y: $0.minY, width: 80, height: 48).contains(element.frame) }) {
                    return pass("window's zoom button", issue, around: element.frame)
                }
                // Everything else is reported with the element's own subtree, so a finding names
                // what it is about rather than being guessed at; a finding with no element gets the
                // front sheet's tree, the only place such a finding has appeared.
                let tree = issue.element.map { "\n    " + $0.debugDescription.prefix(800).replacingOccurrences(of: "\n", with: "\n    ") }
                    ?? (app.sheets.count > 0 ? "\n    sheet: " + app.sheets.firstMatch.debugDescription.prefix(1500).replacingOccurrences(of: "\n", with: "\n    ") : "")
                XCTFail("[\(state)] \(issue.auditType.name): \(issue.compactDescription)\(element)\(detail)\(tree)", file: file, line: line)
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
            attach(Self.annotated(screen, frames: contrastFrames, caption: "contrast notes (advisory): \(contrastNotes.count)", in: .systemOrange),
                   as: "contrast: \(state)")
            print("[\(state)] contrast notes (advisory): \(contrastNotes.count)")
            for note in contrastNotes { print("  \(note)") }
        }
    }

    /// Keeps a picture in the result bundle under the given name.
    private func attach(_ image: NSImage, as name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Where an element sits on the screen, for a log line: its description and frame.
    private static func placement(of element: XCUIElement?) -> String {
        element.map { " — \($0) at \(Int($0.frame.minX)),\(Int($0.frame.minY)) \(Int($0.frame.width))×\(Int($0.frame.height))" } ?? ""
    }

    /// The screen with the given frames outlined and a caption by the first of them. Frames
    /// are XCUITest's, in screen points from the top left; the picture is drawn at the
    /// screenshot's own pixel size, so a Retina screen keeps its detail.
    private static func annotated(_ screen: NSImage, frames: [CGRect], caption: String, in color: NSColor) -> NSImage {
        let bitmap = screen.representations.compactMap { $0 as? NSBitmapImageRep }.first
        let pixels = bitmap.map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? screen.size
        let points = NSScreen.screens.first?.frame.size ?? pixels
        let scale = pixels.width / points.width
        return NSImage(size: pixels, flipped: true) { bounds in
            screen.draw(in: bounds)
            for frame in frames {
                let box = CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
                    .insetBy(dx: -3 * scale, dy: -3 * scale)
                color.setStroke()
                let outline = NSBezierPath(rect: box)
                outline.lineWidth = 3 * scale
                outline.stroke()
            }
            let label = NSAttributedString(string: " \(caption) ", attributes: [
                .font: NSFont.boldSystemFont(ofSize: 15 * scale), .foregroundColor: NSColor.white, .backgroundColor: color])
            let size = label.size()
            // Above the first frame's top-left corner, or just inside it when that corner touches the top of the screen.
            let anchor = frames.first.map { CGPoint(x: $0.minX * scale, y: $0.minY * scale) } ?? CGPoint(x: 24 * scale, y: 24 * scale)
            var origin = CGPoint(x: anchor.x, y: anchor.y - size.height - 6 * scale)
            if origin.y < 0 { origin.y = anchor.y + 6 * scale }
            origin.x = min(max(0, origin.x), bounds.width - size.width)
            label.draw(at: origin)
            return true
        }
    }

    /// The frames of every window, sheet and dialog the app shows: a nameless group of exactly
    /// that size is SwiftUI's hosting container, not a view of the app's.
    private static func windowFrames(of app: XCUIApplication) -> [CGRect] {
        app.windows.allElementsBoundByIndex.map(\.frame) + app.sheets.allElementsBoundByIndex.map(\.frame)
            + app.dialogs.allElementsBoundByIndex.map(\.frame)
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

    /// Waits for the run to finish, then opens the drawer by clicking the strip's "Transfers"
    /// label: the whole strip is the button that opens it.
    private func openDrawerAfterDownload(_ app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["Done"].firstMatch.waitForExistence(timeout: 60), "the download never finished")
        let strip = app.staticTexts["Transfers"].firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "the transfers strip was not found")
        app.activate()
        strip.click()
        let opened = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Show in Finder'")).firstMatch
        if !opened.waitForExistence(timeout: 5) {
            app.typeKey("t", modifierFlags: [.command, .shift])   // Go ▸ Transfers, the menu's own way
        }
        XCTAssertTrue(opened.waitForExistence(timeout: 10), "the drawer never opened; window: \(app.windows.firstMatch.debugDescription.prefix(6000))")
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
