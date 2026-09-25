import XCTest
import AppKit

/// The two title-bar fields: the location box (⌘L) and "Find a column" (⌘F). Each test is one
/// thing that used to go wrong: a click elsewhere left the field holding the keyboard, a second
/// ⌘L lit the location box but left the keyboard in the other field, and the find field's text
/// jumped left when it took focus.
@MainActor
final class TitleBarFieldTests: XCTestCase {

    private var app: XCUIApplication!
    private var home: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rumen-titlebar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["--home", home.path]
        app.launch()
        XCTAssertTrue(app.staticTexts["Open a server"].waitForExistence(timeout: 20))
    }

    override func tearDown() async throws {
        app?.terminate()
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private var location: XCUIElement { app.textFields["location-field"] }
    private var find: XCUIElement { app.textFields["column-search-field"] }
    /// Somewhere plain on the start page: no control, no field.
    private var elsewhere: XCUIElement { app.staticTexts["Open a server"] }

    private func hasFocus(_ element: XCUIElement) -> Bool {
        element.exists && ((element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false)
    }

    /// Focus moves on the next turn of the run loop, so wait for it rather than sample once.
    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("timed out waiting for: \(what)")
    }

    func testAClickElsewhereEndsEitherField() {
        find.click()
        waitFor("find field focused") { hasFocus(find) }
        elsewhere.click()
        waitFor("find field lets go after a click elsewhere") { !hasFocus(find) }

        app.typeKey("l", modifierFlags: .command)
        waitFor("location field focused") { hasFocus(location) }
        elsewhere.click()
        waitFor("the location edit ends after a click elsewhere") { !location.exists }
    }

    /// The reported failure: after focus had gone elsewhere, ⌘L lit the box but a paste went to
    /// the find field or nowhere. Every ⌘L must leave the keyboard in the location box.
    func testCommandLAlwaysTakesTheKeyboard() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        let url = "https://example.invalid/arcgis/rest/services"

        for round in 1...3 {
            app.typeKey("f", modifierFlags: .command)
            waitFor("round \(round): find field focused by ⌘F") { hasFocus(find) }
            XCTAssertFalse(location.exists, "round \(round): ⌘F should end the location edit")

            app.typeKey("l", modifierFlags: .command)
            waitFor("round \(round): location field focused by ⌘L") { hasFocus(location) }
            XCTAssertFalse(hasFocus(find), "round \(round): the find field still has the keyboard")

            pasteboard.clearContents()
            pasteboard.setString(url, forType: .string)
            app.typeKey("v", modifierFlags: .command)
            waitFor("round \(round): the paste lands in the location field") { (location.value as? String) == url }
            XCTAssertEqual(find.value as? String ?? "", "", "round \(round): the paste leaked into the find field")
        }

        // ⌘L while already editing keeps the draft and selects it, so typing replaces it.
        app.typeKey("l", modifierFlags: .command)
        waitFor("still focused after a repeat ⌘L") { hasFocus(location) }
        app.typeText("x")
        waitFor("a repeat ⌘L selected the draft") { (location.value as? String) == "x" }
    }

    /// The text must sit in the same place whether or not the field has the keyboard. The
    /// caret is put at the end, so the leftmost ink is the first glyph either way.
    func testFindTextDoesNotMoveWhenFocused() throws {
        find.click()
        find.typeText("Parcel")
        elsewhere.click()
        waitFor("find field unfocused") { !hasFocus(find) }
        let resting = find.screenshot()

        find.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).click()
        waitFor("find field focused") { hasFocus(find) }
        let editing = find.screenshot()

        for (name, shot) in [("resting", resting), ("editing", editing)] {
            let attachment = XCTAttachment(screenshot: shot)
            attachment.name = "find field, \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let before = try XCTUnwrap(Self.leftmostInk(resting.pngRepresentation), "no text found at rest")
        let after = try XCTUnwrap(Self.leftmostInk(editing.pngRepresentation), "no text found while editing")
        XCTAssertLessThanOrEqual(abs(before - after), 1, "the text moved \(after - before) px when the field took focus")
    }

    /// The first pixel column, from the left, holding anything that is not the background
    /// (taken from the top-left pixel), or nil when the image is blank.
    private static func leftmostInk(_ png: Data) -> Int? {
        guard let bitmap = NSBitmapImageRep(data: png) else { return nil }
        guard let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB) else { return nil }
        func distance(_ color: NSColor) -> CGFloat {
            abs(color.redComponent - background.redComponent) + abs(color.greenComponent - background.greenComponent)
                + abs(color.blueComponent - background.blueComponent)
        }
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), distance(color) > 0.35 { return x }
            }
        }
        return nil
    }
}
