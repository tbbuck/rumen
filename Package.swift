// swift-tools-version: 6.0
import PackageDescription

// ArcGISCore: the headless engine + kit layer, testable with `swift test`.
//
// - CDuckDB / DuckDBKit wrap the locally-installed libduckdb (Homebrew, v1.5.5) via its
//   C API — copied from DuckLake Explorer, plus an Appender and a migration runner.
// - ArcGISKit holds everything ArcGIS: URL normalisation, REST client, crawler, PBF
//   decoding, download planning, and the app database. No UI, no AppKit.
//
// The macOS app (see project.yml) links both products. Homebrew's dylib has an absolute
// install name, so no rpath is needed for local development; bundling is M8.
let duckdbLib = "/opt/homebrew/opt/duckdb/lib"

let package = Package(
    name: "ArcGISCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DuckDBKit", targets: ["DuckDBKit"]),
        .library(name: "ArcGISKit", targets: ["ArcGISKit"]),
    ],
    dependencies: [
        // Esri PBF FeatureCollection decoding (SPEC §5.6). Generated Swift is committed.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    targets: [
        // System module exposing duckdb.h (absolute path — see module.modulemap).
        .systemLibrary(name: "CDuckDB", path: "Sources/CDuckDB"),
        .target(
            name: "DuckDBKit",
            dependencies: ["CDuckDB"],
            linkerSettings: [
                .unsafeFlags(["-L\(duckdbLib)", "-lduckdb"]),
            ]
        ),
        .target(
            name: "ArcGISKit",
            dependencies: [
                "DuckDBKit",
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: [
                // Vendored Esri proto + its licence/README; the generated Swift beside them compiles.
                "Proto/FeatureCollection.proto",
                "Proto/ESRI-README.md",
                "Proto/LICENSE",
                "Proto/README.md",
            ],
            resources: [
                // Numbered SQL migrations, applied in order by the runner (SPEC §7.2).
                .copy("Migrations"),
            ]
        ),
        .testTarget(name: "DuckDBKitTests", dependencies: ["DuckDBKit"]),
        .testTarget(name: "ArcGISKitTests", dependencies: ["ArcGISKit"]),
    ]
)
