// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterPropagationConfigTests.swift
//  LXMFSwiftTests
//
//  Direct unit tests for the cross-actor setters added so test
//  harnesses (and any future programmatic callers) can configure a
//  router's outbound propagation node without round-tripping through
//  an announce. Pins:
//
//    - `setOutboundPropagationNode(_:)` writes to the actor's
//      `outboundPropagationNode` and reads back via a public
//      property access.
//    - `setPropagationStampCost(_:)` writes to the actor's
//      `propagationStampCost` and the value matches on read.
//    - `setOutboundPropagationNode(nil)` clears a previously set
//      node — `nil` is allowed by the Optional type and is the
//      idiomatic "unconfigure" path.
//
//  Reference: Sources/LXMFSwift/Router/LXMRouter.swift
//  `setOutboundPropagationNode` and `setPropagationStampCost`.
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMRouterPropagationConfigTests: XCTestCase {

    // MARK: - Helper

    /// Build a router backed by a unique temp-file DB. Mirrors the
    /// pattern in `LXMRouterDeliveryTests` — WAL mode requires a real
    /// file on disk so `:memory:` won't work here.
    private func makeRouter() async throws -> LXMRouter {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-router-config-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        return try await LXMRouter(identity: Identity(), databasePath: dbPath)
    }

    // MARK: - Tests

    func testSetOutboundPropagationNodePersistsValue() async throws {
        let router = try await makeRouter()

        // Initially nil — no propagation node configured.
        let initial = await router.outboundPropagationNode
        XCTAssertNil(initial)

        // Round-trip a 16-byte hash (the canonical destination hash size).
        let hash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        await router.setOutboundPropagationNode(hash)

        let stored = await router.outboundPropagationNode
        XCTAssertEqual(stored, hash,
            "setOutboundPropagationNode should write to the actor's " +
            "`outboundPropagationNode` so a subsequent .propagated " +
            "outbound knows where to upload the message.")
    }

    func testSetOutboundPropagationNodeAcceptsNilToUnconfigure() async throws {
        let router = try await makeRouter()
        let hash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        await router.setOutboundPropagationNode(hash)
        let afterSet = await router.outboundPropagationNode
        XCTAssertNotNil(afterSet)

        // Clearing the node should reset to nil so the outbound
        // thread treats the next propagated message as "no PN
        // configured" — same gate as never-set.
        await router.setOutboundPropagationNode(nil)
        let afterClear = await router.outboundPropagationNode
        XCTAssertNil(afterClear)
    }

    func testSetPropagationStampCostPersistsValue() async throws {
        let router = try await makeRouter()

        // Default cost is 0 (no work). The setter should overwrite it.
        let initial = await router.propagationStampCost
        XCTAssertEqual(initial, 0)

        // 13 = LXMRouter.PROPAGATION_COST_MIN floor a real PN would
        // advertise. Anything between 0 and 32 is reasonable.
        await router.setPropagationStampCost(13)
        let stored = await router.propagationStampCost
        XCTAssertEqual(stored, 13,
            "setPropagationStampCost should write to the actor's " +
            "`propagationStampCost`. A wrong value here causes the " +
            "sender to under- or over-stamp every propagated message.")

        // Overwrite — last write wins.
        await router.setPropagationStampCost(0)
        let cleared = await router.propagationStampCost
        XCTAssertEqual(cleared, 0)
    }

    func testSettersAreIndependent() async throws {
        // Regression guard: setting one shouldn't reset the other.
        // The setters are tiny but the symmetry between them is the
        // contract the bridge depends on.
        let router = try await makeRouter()
        let hash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        await router.setOutboundPropagationNode(hash)
        await router.setPropagationStampCost(13)

        let storedHash = await router.outboundPropagationNode
        let storedCost = await router.propagationStampCost
        XCTAssertEqual(storedHash, hash)
        XCTAssertEqual(storedCost, 13)

        // Setter call order shouldn't matter.
        await router.setPropagationStampCost(7)
        await router.setOutboundPropagationNode(nil)
        let finalHash = await router.outboundPropagationNode
        let finalCost = await router.propagationStampCost
        XCTAssertNil(finalHash)
        XCTAssertEqual(finalCost, 7)
    }
}
