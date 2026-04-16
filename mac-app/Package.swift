// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "StampScanner",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/groue/GRDBQuery.git", from: "0.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "StampScanner",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "GRDBQuery", package: "GRDBQuery"),
            ],
            path: "Sources/StampScanner"
        ),
        .testTarget(
            name: "StampScannerTests",
            dependencies: ["StampScanner"],
            path: "Tests/StampScannerTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
