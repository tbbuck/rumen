// swift-tools-version: 6.0
import PackageDescription

// RumenCore: the headless engine + kit layer, testable with `swift test`.
//
// - SQLiteKit wraps the system SQLite: the app database (metadata cache, download
//   bookkeeping) and the migration runner. Boring storage for boring data.
// - CDuckDB / DuckDBKit wrap the locally-installed libduckdb (Homebrew, v1.5.5) via its C
//   API — copied from DuckLake Explorer, plus an Appender and prepared statements. DuckDB
//   is the spatial and data engine: extent reprojection, download staging, export, map.
// - RumenKit is the whole engine: URL normalisation, the ArcGIS REST client and the OGC
//   (WMS/WFS/WMTS) client, the crawlers, PBF and JSON decoding, extractability, download
//   planning, export, and the app database. No UI, no AppKit. The ArcGIS-prefixed files
//   are the Esri protocol layer; OGC.swift and its neighbours are the other one.
//
// The macOS app (see project.yml) links the products. Homebrew's dylib has an absolute
// install name, so no rpath is needed for local development; scripts/bundle-duckdb-engine.sh
// bundles it for release.
let duckdbLib = "/opt/homebrew/opt/duckdb/lib"

let package = Package(
    name: "RumenCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SQLiteKit", targets: ["SQLiteKit"]),
        .library(name: "DuckDBKit", targets: ["DuckDBKit"]),
        .library(name: "RumenKit", targets: ["RumenKit"]),
    ],
    dependencies: [
        // Esri PBF FeatureCollection decoding (SPEC §5.6). Generated Swift is committed.
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    targets: [
        .target(
            name: "SQLiteKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
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
            name: "RumenKit",
            dependencies: [
                "SQLiteKit",
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
        .testTarget(name: "SQLiteKitTests", dependencies: ["SQLiteKit"]),
        .testTarget(name: "DuckDBKitTests", dependencies: ["DuckDBKit"]),
        .testTarget(name: "RumenKitTests", dependencies: ["RumenKit"]),
    ]
)
