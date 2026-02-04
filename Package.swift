// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LXMFSwift",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "LXMFSwift",
            targets: ["LXMFSwift"]
        )
    ],
    dependencies: [
        .package(path: "../ReticulumSwift"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.0"),
    ],
    targets: [
        .target(
            name: "LXMFSwift",
            dependencies: [
                "ReticulumSwift",
                .product(name: "GRDB", package: "GRDB.swift"),
                "SWCompression",
            ],
            path: "Sources/LXMFSwift"
        ),
        .testTarget(
            name: "LXMFSwiftTests",
            dependencies: ["LXMFSwift"],
            path: "Tests/LXMFSwiftTests"
        )
    ]
)
