// swift-tools-version: 6.1
// The screen benchmark harness: the app's outline and A2UI parsers, its prompts and its hosted
// model client, compiled for macOS with the A2UI SDK, so the on-device model can be measured
// natively (its calls fail in the simulator). `run.sh` copies the app's files into
// Sources/ScreenBenchmarkHarness/App/ before each build.
import PackageDescription

let package = Package(
    name: "ScreenBenchmarkHarness",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(url: "https://github.com/a2ui-project/a2ui", revision: "07735d6a654ae3ba25951a8753ddd57b344b1169"),
        // The version the A2UI package resolves; direct, since LayerCatalog imports JSONSchema
        // and the importer and exporter import OrderedJSON.
        .package(url: "https://github.com/ajevans99/swift-json-schema", .upToNextMinor(from: "0.13.1")),
    ],
    targets: [
        .executableTarget(
            name: "ScreenBenchmarkHarness",
            dependencies: [
                .product(name: "A2UISwiftCore", package: "a2ui"),
                .product(name: "BasicCatalog", package: "a2ui"),
                .product(name: "JSONSchema", package: "swift-json-schema"),
                .product(name: "OrderedJSON", package: "swift-json-schema"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
