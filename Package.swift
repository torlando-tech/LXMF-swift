// swift-tools-version: 5.9

// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
        // Pinned to the reticulum-swift `from:` semver constraint rather than
        // tracking `branch: "main"`. Tracking a branch makes resolution
        // non-reproducible: every fresh checkout pulls whatever main HEAD
        // happens to be, and downstream consumers (Columba-iOS) inherit
        // that drift transitively. `from:` lets SPM pick the latest
        // semver-compatible release tag while still allowing minor/patch
        // upgrades to flow through automatically.
        .package(url: "https://github.com/torlando-tech/reticulum-swift.git", from: "0.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/tsolomko/SWCompression.git", from: "4.8.0"),
    ],
    targets: [
        .target(
            name: "LXMFSwift",
            dependencies: [
                .product(name: "ReticulumSwift", package: "reticulum-swift"),
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
