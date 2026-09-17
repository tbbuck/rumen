import XCTest

/// Where the keyboard goes at launch. Nothing in the app asks for focus until the user does
/// (⌘L, ⌘F, or the tree after a server opens), so on the start page no text field should
/// hold it, and the first thing typed must not land in the URL bar or the search box.
@MainActor
final class LaunchFocusTests: XCTestCase {

    func testNoTextFieldHasTheKeyboardOnTheStartPage() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("arcgis-explorer-focus-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let app = XCUIApplication()
        app.launchArguments = ["--home", home.path]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.staticTexts["Open a server"].waitForExistence(timeout: 20))
        let fields = app.textFields.allElementsBoundByIndex
        XCTAssertFalse(fields.isEmpty, "the start page has a URL field and the title bar a search field")
        for field in fields {
            let focused = (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
            XCTAssertFalse(focused, "\(field.placeholderValue ?? field.label) took the keyboard at launch")
        }
    }
}
