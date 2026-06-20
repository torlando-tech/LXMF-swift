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
        // Pinned to reticulum-swift 0.3.0 — the release that drops
        // `destinationHash` from `sendLinkData` (breaking) and aligns
        // link DATA send with python parity. Floor must be ≥ 0.3.0
        // because LXMF-swift now uses the new `sendLinkData(packet:)`
        // signature; an older reticulum-swift would not compile.
        .package(url: "https://github.com/torlando-tech/reticulum-swift.git", from: "0.3.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        // Cap below 4.9.0: SWCompression 4.9.0 raised its floor to macOS 14 / iOS 17,
        // above this library's macOS 13 / iOS 16 (which matches the sibling ports
        // reticulum-swift + LXST-swift and Columba's iOS 16 device-support floor).
        // `Package.resolved` is gitignored, so CI's `swift package resolve` otherwise
        // picks the latest (4.9.0) and fails the build with a platform conflict. Raising
        // the suite to iOS 17 would drop iOS 16 devices — a user-facing call, not a CI
        // hygiene one — so pin to the 4.8.x line (4.8.7 is macOS 10.13 / iOS 11) instead.
        .package(url: "https://github.com/tsolomko/SWCompression.git", "4.8.0" ..< "4.9.0"),
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
