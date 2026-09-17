import XCTest

/// Cold launch to a usable window, measured by XCTest's launch metric over five launches
/// against a scratch home. There is no baseline yet, so this records rather than fails; set
/// one from a run's result bundle in Xcode when the number is worth defending.
@MainActor
final class LaunchPerformanceTests: XCTestCase {

    func testLaunchToStartPage() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("arcgis-explorer-launch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchArguments = ["--home", home.path]
            app.launch()
            _ = app.staticTexts["Open a server"].waitForExistence(timeout: 20)
            app.terminate()
        }
    }
}
