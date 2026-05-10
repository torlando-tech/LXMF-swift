// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterProofCallbackTests.swift
//  LXMFSwiftTests
//
//  Direct unit coverage for the helper extracted from `sendDirect`
//  that registers a delivery-proof callback before sending a link
//  DATA packet, and removes the callback if the send fails. Without
//  this hook small DIRECT messages stop at `.sent` even when the
//  receiver has acked.
//
//  Reference: Sources/LXMFSwift/Router/LXMRouter+Delivery.swift
//  `sendLinkDataWithProofCallback`.
//

import XCTest
import CryptoKit
@testable import LXMFSwift
import ReticulumSwift

final class LXMRouterProofCallbackTests: XCTestCase {

    // MARK: - Helpers

    /// Build a router backed by a unique temp-file DB.
    private func makeRouter() async throws -> LXMRouter {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-proof-cb-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        return try await LXMRouter(identity: Identity(), databasePath: dbPath)
    }

    /// Build an `.active` Link and register it with the transport. The
    /// link's `attachedInterfaceId` is set to `interfaceId`, which is
    /// what `transport.sendLinkData` consults — without this wiring the
    /// new (post-PR-#16) silent-drop path would skip transmission and
    /// the test would observe zero bytes on the mock interface.
    /// Returns the link's `linkId` so the caller can build a packet
    /// addressed to it.
    private func registerActiveLink(
        on transport: ReticulumTransport, attachedTo interfaceId: String
    ) async throws -> Data {
        let identity = Identity()
        let dest = Destination(
            identity: identity, appName: "test", aspects: ["proof-cb"]
        )

        let encKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let sigKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let signaling = IncomingLinkRequest.encodeSignaling(
            mtu: 500, mode: LinkConstants.MODE_DEFAULT
        )
        var requestData = Data()
        requestData.append(encKey)
        requestData.append(sigKey)
        requestData.append(signaling)
        let header = PacketHeader(
            headerType: .header1,
            hasContext: false,
            transportType: .broadcast,
            destinationType: .single,
            packetType: .linkRequest,
            hopCount: 0
        )
        let lrPacket = Packet(
            header: header,
            destination: dest.hash,
            context: 0x00,
            data: requestData
        )
        let incoming = try IncomingLinkRequest(data: requestData, packet: lrPacket)
        let link = Link(incomingRequest: incoming, destination: dest, identity: identity)
        // Note: we intentionally do NOT call _setStateForTesting(.active)
        // — that helper is internal to reticulum-swift's own tests and
        // not exported. It's also unnecessary here: `sendLinkData` reads
        // `activeLinks[linkId]?.attachedInterfaceId` regardless of the
        // link's state, so a freshly-constructed (pending) link is
        // sufficient to exercise the helper path under test.
        await link.setAttachedInterface(interfaceId)
        await transport.registerLink(link)
        return await link.linkId
    }

    /// A link DATA packet addressed to `linkId`. The helper does not
    /// inspect packet contents — only the truncated hash matters for
    /// the proof-callback key — so any plausibly-shaped link packet
    /// is fine.
    private func makeLinkPacket(linkId: Data) -> Packet {
        let header = PacketHeader(
            headerType: .header1,
            hasContext: false,
            transportType: .broadcast,
            destinationType: .link,
            packetType: .data,
            hopCount: 0
        )
        return Packet(
            header: header,
            destination: linkId,
            context: 0x00,
            data: Data("ciphertext-stand-in".utf8)
        )
    }

    // MARK: - Tests

    func testSendLinkDataWithProofCallbackEmitsBytesOnSuccess() async throws {
        // Success path: the helper should register a proof callback,
        // call `transport.sendLinkData`, and not throw. We observe the
        // send succeeded by capturing the bytes on a mock interface.
        //
        // As of reticulum-swift 0.3.0 (PR #16), `sendLinkData` only
        // transmits when the packet's destination linkId resolves to
        // a registered Link with an `attachedInterfaceId` — mirrors
        // python `Transport.outbound:1124-1130`. Setup must therefore
        // register an active Link pinned to the mock's interface
        // before sending; the helper itself is unchanged but its
        // dependency now requires this realistic wiring.
        let router = try await makeRouter()
        let transport = ReticulumTransport()
        let mock = CapturingInterface(id: "proof-cb-success")
        try await transport.addInterface(mock)
        await router.setTransport(transport)

        let linkId = try await registerActiveLink(on: transport, attachedTo: mock.id)
        let packet = makeLinkPacket(linkId: linkId)
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        try await router.sendLinkDataWithProofCallback(
            packet: packet,
            messageHash: messageHash,
            transport: transport
        )

        let sent = await mock.drain()
        XCTAssertGreaterThanOrEqual(sent.count, 1,
            "Expected at least one outbound packet on the mock " +
            "interface; got \(sent.count). Helper either short-" +
            "circuited the send or the link wasn't wired to the mock " +
            "(check registerActiveLink set attachedInterfaceId).")
    }

    func testSendLinkDataWithProofCallbackRemovesCallbackOnSendFailure() async throws {
        // Error path: when `transport.sendLinkData` throws, the helper
        // must remove the just-registered proof callback so a stale
        // entry doesn't sit in `pendingProofCallbacks` indefinitely
        // (and so a later proof for an unrelated outbound doesn't
        // accidentally fire this stale entry).
        //
        // We can't read `pendingProofCallbacks` directly (it's
        // private), so we observe the rethrow + verify the helper
        // didn't swallow the underlying interface error.
        //
        // Same setup pattern as the success test — the link MUST be
        // pinned to the (throwing) interface so sendLinkData actually
        // routes to it; otherwise the new silent-drop path would
        // return without throwing and the test would mis-pass for the
        // wrong reason.
        let router = try await makeRouter()
        let transport = ReticulumTransport()
        let mock = ThrowingInterface(id: "proof-cb-error")
        try await transport.addInterface(mock)
        await router.setTransport(transport)

        let linkId = try await registerActiveLink(on: transport, attachedTo: mock.id)
        let packet = makeLinkPacket(linkId: linkId)
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        do {
            try await router.sendLinkDataWithProofCallback(
                packet: packet,
                messageHash: messageHash,
                transport: transport
            )
            XCTFail("sendLinkDataWithProofCallback must rethrow when " +
                    "the underlying interface send throws; otherwise " +
                    "the caller has no way to know the proof callback " +
                    "was just orphaned.")
        } catch {
            // Any error is acceptable — point is the helper rethrew
            // and didn't swallow the interface failure. The exact
            // type depends on what `transport.sendLinkData` wraps it
            // in, which is reticulum-swift's concern.
        }
    }

    // MARK: - handleOutboundResourceFailed — map cleanup on failure

    /// Greptile review on PR #7 (issue 1): when an outbound resource
    /// transfer concluded in a non-`.complete` state, the prior
    /// `LXMFOutboundResourceHandler.resourceConcluded` early-returned
    /// without removing the resource hash from
    /// `pendingResourceDeliveries` and (for prop sends)
    /// `pendingPropagationResources`. Across the router's lifetime
    /// those maps grew without bound on every link drop / PN timeout
    /// / cancellation, AND if the same resource hash ever did
    /// re-complete the wrong per-method state handler could fire.
    ///
    /// The fix routes non-complete resource conclusions through
    /// `LXMRouter.handleOutboundResourceFailed`, which always reclaims
    /// both map entries and writes a python-faithful state transition
    /// (LXMF/LXMessage.py:592-609). These tests pin the map-cleanup
    /// guarantee — the part most prone to regressing because the
    /// failure path is rarely hit in development.

    func testOutboundResourceFailedReclaimsMapsForDirectPath() async throws {
        let router = try await makeRouter()
        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        // Seed only `pendingResourceDeliveries` (DIRECT path —
        // sendDirect's resource branch does NOT insert into
        // `pendingPropagationResources`).
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: messageHash)

        let beforeDeliveries = await router.pendingResourceDeliveries.count
        let beforeProp = await router.pendingPropagationResources.count
        XCTAssertEqual(beforeDeliveries, 1, "Setup: pendingResourceDeliveries must contain 1 entry pre-fail")
        XCTAssertEqual(beforeProp, 0, "Setup: pendingPropagationResources must be empty for DIRECT path")

        await router.handleOutboundResourceFailed(
            resourceHash: resourceHash, resourceState: .failed
        )

        let afterDeliveries = await router.pendingResourceDeliveries.count
        let afterProp = await router.pendingPropagationResources.count
        XCTAssertEqual(afterDeliveries, 0,
            "DIRECT resource failure must clear pendingResourceDeliveries — " +
            "leaving entries here was the bug greptile flagged on PR #7. " +
            "Got \(afterDeliveries) entries.")
        XCTAssertEqual(afterProp, 0,
            "pendingPropagationResources must remain empty for DIRECT failure; got \(afterProp).")
    }

    func testOutboundResourceFailedReclaimsMapsForPropagationPath() async throws {
        let router = try await makeRouter()
        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        // Seed BOTH maps — PROPAGATED resource path inserts into
        // `pendingPropagationResources` AND `pendingResourceDeliveries`
        // (LXMRouter+Propagation.swift:241-249).
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: messageHash)
        await router.markPendingPropagationResource(resourceHash: resourceHash)

        let beforeDeliveries = await router.pendingResourceDeliveries.count
        let beforeProp = await router.pendingPropagationResources.count
        XCTAssertEqual(beforeDeliveries, 1, "Setup: pendingResourceDeliveries seeded")
        XCTAssertEqual(beforeProp, 1, "Setup: pendingPropagationResources seeded")

        await router.handleOutboundResourceFailed(
            resourceHash: resourceHash, resourceState: .failed
        )

        let afterDeliveries = await router.pendingResourceDeliveries.count
        let afterProp = await router.pendingPropagationResources.count
        XCTAssertEqual(afterDeliveries, 0,
            "PROPAGATED resource failure must clear pendingResourceDeliveries; got \(afterDeliveries).")
        XCTAssertEqual(afterProp, 0,
            "PROPAGATED resource failure must clear pendingPropagationResources — " +
            "this is the half greptile specifically called out as leaking. " +
            "Got \(afterProp) entries.")
    }

    func testOutboundResourceFailedReclaimsMapsForRejectedState() async throws {
        // Mirrors `LXMessage.__resource_concluded` (LXMF/LXMessage.py
        // :596-601): on `RNS.Resource.REJECTED` python sets
        // `state = REJECTED` rather than retrying. The map cleanup
        // must still happen — this test pins that we don't regress
        // by special-casing `.rejected` and accidentally skipping the
        // reclaim.
        let router = try await makeRouter()
        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: messageHash)
        await router.markPendingPropagationResource(resourceHash: resourceHash)

        await router.handleOutboundResourceFailed(
            resourceHash: resourceHash, resourceState: .rejected
        )

        let afterDeliveries = await router.pendingResourceDeliveries.count
        let afterProp = await router.pendingPropagationResources.count
        XCTAssertEqual(afterDeliveries, 0,
            ".rejected must still reclaim pendingResourceDeliveries; got \(afterDeliveries).")
        XCTAssertEqual(afterProp, 0,
            ".rejected must still reclaim pendingPropagationResources; got \(afterProp).")
    }

    func testOutboundResourceFailedNoOpOnUnknownResourceHash() async throws {
        // Defensive: if `resourceConcluded` fires with a hash we
        // don't have in either map (could happen on a doubly-fired
        // callback or a hash collision with a legitimately-cancelled
        // outbound), the failure path must not crash and must not
        // mutate any other entries.
        let router = try await makeRouter()
        let stableHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let stableMsgHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        // Seed an unrelated entry that must survive.
        await router.setPendingResourceDelivery(resourceHash: stableHash, messageHash: stableMsgHash)

        let unknownHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.handleOutboundResourceFailed(
            resourceHash: unknownHash, resourceState: .failed
        )

        let stillThere = await router.pendingResourceDeliveries[stableHash]
        XCTAssertEqual(stillThere, stableMsgHash,
            "Unknown-hash failure must not touch unrelated map entries; " +
            "the unrelated stableHash entry was clobbered.")
    }
}

// MARK: - Test-only LXMRouter helpers
//
// `pendingResourceDeliveries` / `pendingPropagationResources` are
// `public var` fields on the LXMRouter actor, but actor-isolated state
// can't be mutated directly from outside the actor — every write needs
// to be funneled through an actor-isolated function. These helpers are
// the minimal surface required to seed the maps for the failure-path
// tests above; they're test-only so I'm not exposing
// general-purpose mutators on the production API.

extension LXMRouter {
    fileprivate func setPendingResourceDelivery(resourceHash: Data, messageHash: Data) {
        pendingResourceDeliveries[resourceHash] = messageHash
    }

    fileprivate func markPendingPropagationResource(resourceHash: Data) {
        pendingPropagationResources.insert(resourceHash)
    }
}

// MARK: - Mock interfaces

/// Mock interface that records every byte sent through it. Same shape
/// as TransportSendTests' MockInterface in reticulum-swift; copied
/// here because LXMF-swift can't link to that test target.
private actor CapturingInterface: NetworkInterface {
    let id: String
    let config: InterfaceConfig
    nonisolated var state: InterfaceState { .connected }

    private var sentPackets: [Data] = []

    init(id: String) {
        self.id = id
        self.config = InterfaceConfig(
            id: id, name: id, type: .tcp,
            enabled: true, mode: .full,
            host: "127.0.0.1", port: 0
        )
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_ data: Data) async throws { sentPackets.append(data) }
    func setDelegate(_ delegate: any InterfaceDelegate) async {}

    func drain() -> [Data] {
        let out = sentPackets
        sentPackets = []
        return out
    }
}

/// Mock interface whose `send` always throws. Used to exercise the
/// error-cleanup path in the helper (the do/catch around sendLinkData
/// that calls `removeProofCallback` and rethrows).
private actor ThrowingInterface: NetworkInterface {
    let id: String
    let config: InterfaceConfig
    nonisolated var state: InterfaceState { .connected }

    init(id: String) {
        self.id = id
        self.config = InterfaceConfig(
            id: id, name: id, type: .tcp,
            enabled: true, mode: .full,
            host: "127.0.0.1", port: 0
        )
    }

    func connect() async throws {}
    func disconnect() async {}
    func send(_ data: Data) async throws {
        struct InterfaceSendDeliberatelyFails: Error {}
        throw InterfaceSendDeliberatelyFails()
    }
    func setDelegate(_ delegate: any InterfaceDelegate) async {}
}
