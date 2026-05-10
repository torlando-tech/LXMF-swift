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
        // Temporarily pinned to fix/link-data-no-header2-conversion while
        // the upstream HEADER_2-conversion fix for link DATA packets is
        // unreleased. Revert to `from: "0.2.x"` once a release tag exists.
        // Tracking a branch makes resolution non-reproducible across
        // checkouts; this pin must come off before merging back to main.
        .package(url: "https://github.com/torlando-tech/reticulum-swift.git", branch: "fix/link-data-no-header2-conversion"),
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
        // Cross-impl conformance harness for the
        // torlando-tech/lxmf-conformance test suite. Speaks JSON-RPC
        // over stdio against the Python (and eventually Kotlin)
        // bridges so cross-impl tests can drive Swift LXMF through
        // the same scenarios. Build with:
        //
        //   swift build -c release --product LXMFConformanceBridge
        //
        // The lxmf-conformance pytest fixture auto-detects the
        // resulting binary at .build/release/LXMFConformanceBridge
        // (or honors CONFORMANCE_SWIFT_BRIDGE_CMD).
        .executableTarget(
            name: "LXMFConformanceBridge",
            dependencies: [
                "LXMFSwift",
                .product(name: "ReticulumSwift", package: "reticulum-swift"),
            ],
            path: "Sources/LXMFConformanceBridge"
        ),
        .testTarget(
            name: "LXMFSwiftTests",
            dependencies: ["LXMFSwift"],
            path: "Tests/LXMFSwiftTests"
        )
    ]
)
