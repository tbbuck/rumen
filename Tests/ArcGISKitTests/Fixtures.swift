import Foundation
import XCTest

/// Recorded ArcGIS REST responses under `Fixtures/` at the repo root (see
/// `scripts/record_fixtures.sh`), resolved from this file's location so the test runner's
/// working directory doesn't matter.
enum Fixtures {
    static let directory: URL = URL(fileURLWithPath: #filePath)   // Tests/ArcGISKitTests/Fixtures.swift
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: url(name))
    }
}
