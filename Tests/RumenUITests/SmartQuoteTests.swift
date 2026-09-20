import XCTest

/// Typing a quote must produce a quote.
///
/// AppKit rewrites `'` to `‘…’` and `--` to `–` as you type, following the system's "smart
/// quotes and dashes" setting, and the app's boxes used to inherit that. In a where clause or a
/// SQL statement it is silent corruption: the server is asked something the user never wrote,
/// and the rejection names the parameter rather than the character. This drives the real keyboard
/// against the real fields, because that is the one layer a client-side test cannot reach.
///
/// Requires automation mode on the host running it (see the VM scripts):
/// `sudo automationmodetool enable-automationmode-without-authentication`.
@MainActor
final class SmartQuoteTests: XCTestCase {

    private var server: FixtureServer!
    private var home: URL!
    private var app: XCUIApplication!

    /// The pair AppKit substitutes for `'`, plus the en dash it substitutes for `--`.
    private static let curly = ["\u{2018}", "\u{2019}", "\u{201C}", "\u{201D}", "\u{2013}"]

    override func setUp() async throws {
        continueAfterFailure = true
        server = try FixtureServer()
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rumen-quotes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
        server = nil
        if let home { try? FileManager.default.removeItem(at: home) }
    }

    private func assertNoSubstitution(_ typed: String, _ got: String, in field: String) {
        for mark in Self.curly where got.contains(mark) {
            XCTFail("\(field) turned what was typed into \(got) — it contains U+\(String(mark.unicodeScalars.first!.value, radix: 16, uppercase: true))")
        }
        XCTAssertEqual(got, typed, "\(field) did not keep what was typed")
    }

    /// The where clause: the box this bug was found in.
    func testWhereClauseKeepsStraightQuotes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--home", home.path, "--open", server.layerURL, "--tab", "query"]
        app.launch()
        self.app = app
        XCTAssertTrue(app.staticTexts["Towns"].firstMatch.waitForExistence(timeout: 30), "the layer page never appeared")

        let box = app.textViews["Where clause"].firstMatch
        XCTAssertTrue(box.waitForExistence(timeout: 10), "the where box never appeared")
        box.click()
        box.typeKey("a", modifierFlags: .command)
        let clause = "NAME='WD/2004/0856/F'"
        box.typeText(clause)

        let got = (box.value as? String) ?? ""
        assertNoSubstitution(clause, got, in: "The where clause")
    }

    /// The SQL box over a stored file shares the editor, and `--` there is a comment.
    func testSQLBoxKeepsStraightQuotesAndDoubleDashes() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--home", home.path, "--open", server.layerURL, "--tab", "stored"]
        app.launch()
        self.app = app

        let box = app.textViews["SQL over the stored file"].firstMatch
        guard box.waitForExistence(timeout: 30) else {
            throw XCTSkip("the stored tab has no file to query in this fixture")
        }
        box.click()
        box.typeKey("a", modifierFlags: .command)
        let sql = "SELECT * FROM t WHERE name='x' -- note"
        box.typeText(sql)

        let got = (box.value as? String) ?? ""
        assertNoSubstitution(sql, got, in: "The SQL box")
    }

    /// A single-line field edits through the window's shared field editor rather than a view the
    /// app configures, so it is a separate path and needs its own proof.
    func testURLFieldKeepsWhatWasTyped() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--home", home.path]
        app.launch()
        self.app = app
        XCTAssertTrue(app.staticTexts["Open a server"].waitForExistence(timeout: 20))

        let field = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS 'ArcGIS'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the URL field never appeared")
        field.click()
        let typed = "https://example.gov.uk/x?q='a'--b"
        field.typeText(typed)

        let got = (field.value as? String) ?? ""
        assertNoSubstitution(typed, got, in: "The URL field")
    }
}
