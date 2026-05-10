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

    // MARK: - handleOutboundResourceFailed — re-enqueue into pendingOutbound

    /// Greptile review (3/5 confidence) on PR #7: when a resource
    /// transfer fails mid-session, `processOutbound` has already
    /// removed the message from `pendingOutbound` (via
    /// `indicesToRemove` immediately after `sendPropagated` /
    /// `sendDirect` returns). Without a periodic DB → queue reload,
    /// the failed message disappears from in-memory retry until app
    /// restart.
    ///
    /// `handleOutboundResourceFailed` now re-loads the LXMessage
    /// from the DB after writing state=.outbound, then appends to
    /// `pendingOutbound` so the next `processOutbound` tick picks it
    /// up. Documented in port-deviations.md as a swift-port band-aid
    /// for the broader optimistic-remove divergence from python.

    func testOutboundResourceFailedReenqueuesMessageForRetryablePropagationFailure() async throws {
        let router = try await makeRouter()

        // Seed a real LXMessage in the DB so the re-enqueue path can
        // load it back. The minimal valid shape is a packed
        // PROPAGATED message — sourceIdentity / destinationHash /
        // content are enough; the message just needs to round-trip
        // through `database.saveMessage` and back via `getMessage`.
        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("retry-me".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        _ = try msg.pack()  // populates msg.hash + msg.packed
        try await router.testSaveMessage(msg)

        // Simulate the state at the moment a resource failure fires:
        // processOutbound has already inserted into the maps + removed
        // from pendingOutbound. We seed the maps directly.
        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: msg.hash)
        await router.markPendingPropagationResource(resourceHash: resourceHash)
        let setupPending = await router.pendingOutbound.count
        XCTAssertEqual(setupPending, 0,
            "Setup: pendingOutbound should be empty (mirrors post-`indicesToRemove` state).")

        // Trigger the failure path.
        await router.handleOutboundResourceFailed(
            resourceHash: resourceHash, resourceState: .failed
        )

        // The maps must be cleared (existing invariant) AND the
        // message must be back in pendingOutbound — this is the
        // greptile-3/5 bug fix.
        let afterProp = await router.pendingPropagationResources.count
        let afterDeliveries = await router.pendingResourceDeliveries.count
        XCTAssertEqual(afterProp, 0, "pendingPropagationResources should be reclaimed.")
        XCTAssertEqual(afterDeliveries, 0, "pendingResourceDeliveries should be reclaimed.")

        let pendingHashes = await router.pendingOutbound.map { $0.hash }
        XCTAssertTrue(pendingHashes.contains(msg.hash),
            "Failed PROPAGATED resource transfer MUST be re-enqueued for " +
            "retry on the next processOutbound tick. Without this, the " +
            "message disappears from in-memory state and is only retried " +
            "on app re-launch (greptile PR #7, 3/5 confidence). " +
            "pendingOutbound count=\(pendingHashes.count)")

        // The re-enqueued message must reflect the failure semantics:
        // state=.outbound (retryable), nextDeliveryAttempt set in the
        // future so processOutbound doesn't immediately re-fire.
        let reenqueued = await router.pendingOutbound.first { $0.hash == msg.hash }!
        XCTAssertEqual(reenqueued.state, .outbound,
            "Re-enqueued message must have state=.outbound for retry " +
            "(python LXMessage.py:608). Got \(reenqueued.state).")
        if let nextAttempt = reenqueued.nextDeliveryAttempt {
            XCTAssertGreaterThan(nextAttempt, Date(),
                "Re-enqueued message must have a future nextDeliveryAttempt " +
                "so processOutbound's next tick doesn't immediately re-fire " +
                "without backoff. Got \(nextAttempt).")
        } else {
            XCTFail("Re-enqueued message must have nextDeliveryAttempt set " +
                    "to enforce backoff; was nil.")
        }
    }

    func testOutboundResourceFailedSkipsReenqueueForCancelledPropagation() async throws {
        // PROPAGATED path with resourceState=.cancelled → terminal,
        // NOT retried. Python `__propagation_resource_concluded`
        // (LXMessage.py:607) guards retry with
        // `if self.state != CANCELLED`. Greptile review (4/5 conf)
        // flagged the earlier swift port for blindly retrying on
        // any non-complete state, which would silently burn the
        // retry budget on a peer-cancelled transfer.
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("cancelled-prop".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)

        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: msg.hash)
        await router.markPendingPropagationResource(resourceHash: resourceHash)

        await router.handleOutboundResourceFailed(
            resourceHash: resourceHash, resourceState: .cancelled
        )

        let pendingHashes = await router.pendingOutbound.map { $0.hash }
        XCTAssertFalse(pendingHashes.contains(msg.hash),
            "Cancelled PROPAGATED resource MUST NOT be re-enqueued — " +
            "python LXMessage.py:607 treats CANCELLED as terminal. " +
            "Got count=\(pendingHashes.count)")

        // Maps still get reclaimed even on cancelled (matching the
        // unconditional-cleanup invariant from the prior fix).
        let afterProp = await router.pendingPropagationResources.count
        let afterDeliveries = await router.pendingResourceDeliveries.count
        XCTAssertEqual(afterProp, 0,
            "Cancellation must still reclaim pendingPropagationResources.")
        XCTAssertEqual(afterDeliveries, 0,
            "Cancellation must still reclaim pendingResourceDeliveries.")
    }

    func testOutboundResourceFailedSkipsReenqueueForCancelledDirect() async throws {
        // Same as above but for the DIRECT path. Python guard at
        // LXMessage.py:598 (same `if self.state != CANCELLED`).
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("cancelled-direct".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)

        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: msg.hash)
        // No markPendingPropagationResource — this is the DIRECT path.

        await router.handleOutboundResourceFailed(
            resourceHash: resourceHash, resourceState: .cancelled
        )

        let pendingHashes = await router.pendingOutbound.map { $0.hash }
        XCTAssertFalse(pendingHashes.contains(msg.hash),
            "Cancelled DIRECT resource MUST NOT be re-enqueued — " +
            "python LXMessage.py:598. Got count=\(pendingHashes.count)")
    }

    func testOutboundResourceFailedSkipsReenqueueForTerminalRejectedDirect() async throws {
        // DIRECT path with resourceState=.rejected → state=.rejected
        // (python LXMessage.py:597). Rejected is terminal; the message
        // is NOT re-enqueued for retry. The DB row stays with the
        // rejected state for the UI to render.
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("rejected-msg".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)

        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: msg.hash)
        // No markPendingPropagationResource — this is the DIRECT path.

        await router.handleOutboundResourceFailed(
            resourceHash: resourceHash, resourceState: .rejected
        )

        let pendingHashes = await router.pendingOutbound.map { $0.hash }
        XCTAssertFalse(pendingHashes.contains(msg.hash),
            "Rejected DIRECT resource MUST NOT be re-enqueued — python " +
            "LXMessage.py:597 treats REJECTED as terminal. " +
            "pendingOutbound count=\(pendingHashes.count)")
    }

    // MARK: - handlePropagationAccepted + handleResourceTransferComplete dispatch

    /// Helper: poll the DB until the message's state matches `expected`
    /// (or fail after `timeout`). Both `handlePropagationAccepted` and
    /// `handleDeliveryProofReceived` use `Task.detached` to write the
    /// DB asynchronously — we have to wait briefly. ms-scale is fine
    /// for an in-process SQLite.
    private func waitForMessageState(
        _ router: LXMRouter, messageHash: Data, expected: LXMessageState,
        timeout: TimeInterval = 2.0
    ) async throws -> LXMessageState? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let msg = try await router.testGetMessage(id: messageHash)
            if let s = msg?.state, s == expected {
                return s
            }
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }
        return try await router.testGetMessage(id: messageHash)?.state
    }

    /// `handlePropagationAccepted` is the new (PR #7) terminal-state
    /// handler for PROPAGATED resource transfers — invoked when
    /// RESOURCE_PRF arrives from the propagation node. Per python
    /// `LXMessage.__mark_propagated` (LXMessage.py:568-578) it must
    /// transition the message to state=`.sent` (NOT `.delivered`).
    /// Pinning this is critical: regressing to `.delivered` would
    /// reintroduce the double-checkmark lie that triggered the whole
    /// state-split rework in `b2e14cd`.
    func testHandlePropagationAcceptedTransitionsToSent() async throws {
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("prop-accepted".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)

        await router.handlePropagationAccepted(messageHash: msg.hash)

        let finalState = try await waitForMessageState(
            router, messageHash: msg.hash, expected: .sent
        )
        XCTAssertEqual(finalState, .sent,
            "handlePropagationAccepted must transition DB state to " +
            ".sent per python LXMessage.py:568-578 — anything else " +
            "(especially .delivered) reintroduces the false-positive " +
            "delivery confirmation. Got \(String(describing: finalState)).")
    }

    /// `handleResourceTransferComplete` dispatches by membership in
    /// `pendingPropagationResources`: when present, route to
    /// `handlePropagationAccepted` (PROPAGATED → state=.sent); when
    /// absent, route to `handleDeliveryProofReceived` (DIRECT →
    /// state=.delivered). This test pins the PROPAGATED branch.
    func testHandleResourceTransferCompleteForPropagationRoutesToSent() async throws {
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("prop-resource-complete".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)

        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: msg.hash)
        await router.markPendingPropagationResource(resourceHash: resourceHash)

        await router.handleResourceTransferComplete(resourceHash: resourceHash)

        let finalState = try await waitForMessageState(
            router, messageHash: msg.hash, expected: .sent
        )
        XCTAssertEqual(finalState, .sent,
            "handleResourceTransferComplete must dispatch PROPAGATED " +
            "resources to handlePropagationAccepted (state=.sent). " +
            "Got \(String(describing: finalState)). A .delivered here " +
            "means the dispatch lookup in pendingPropagationResources " +
            "missed and the DIRECT branch fired wrongly.")

        // Both maps should be cleaned post-dispatch (the
        // handleResourceTransferComplete `.removeValue` + `.remove`
        // calls).
        let afterDeliveries = await router.pendingResourceDeliveries.count
        let afterProp = await router.pendingPropagationResources.count
        XCTAssertEqual(afterDeliveries, 0, "Maps must be cleaned post-dispatch.")
        XCTAssertEqual(afterProp, 0, "Maps must be cleaned post-dispatch.")
    }

    /// DIRECT path through the same dispatcher → state=.delivered.
    func testHandleResourceTransferCompleteForDirectRoutesToDelivered() async throws {
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("direct-resource-complete".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)

        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: msg.hash)
        // Deliberately NOT in pendingPropagationResources — this is
        // the DIRECT path.

        await router.handleResourceTransferComplete(resourceHash: resourceHash)

        let finalState = try await waitForMessageState(
            router, messageHash: msg.hash, expected: .delivered
        )
        XCTAssertEqual(finalState, .delivered,
            "DIRECT resource transfer completion must dispatch to " +
            "handleDeliveryProofReceived → state=.delivered. " +
            "Got \(String(describing: finalState)).")
    }

    // MARK: - send* guard-clause coverage
    //
    // The send paths (sendPropagated / sendDirect / sendOpportunistic)
    // each have a stack of early-return guard clauses before any real
    // network work begins. These are trivial to test (no transport
    // setup needed) and they cover the bulk of the "first few lines"
    // of each function — which means a non-trivial chunk of coverage
    // for very little test surface.

    func testSendPropagatedThrowsWhenPropagationNodeNotSet() async throws {
        let router = try await makeRouter()
        // Deliberately don't call setOutboundPropagationNode — that's
        // the guard under test.
        var msg = LXMessage(
            destinationHash: Data((0..<16).map { _ in 0xAB }),
            sourceIdentity: Identity(),
            content: Data("test".utf8),
            title: Data(), fields: nil, desiredMethod: .propagated
        )
        _ = try msg.pack()

        do {
            try await router.sendPropagated(&msg)
            XCTFail("sendPropagated must throw when outboundPropagationNode is nil")
        } catch LXMFError.propagationNodeNotSet {
            // expected
        } catch {
            XCTFail("expected propagationNodeNotSet, got \(error)")
        }
    }

    func testSendPropagatedThrowsWhenMessageNotPacked() async throws {
        let router = try await makeRouter()
        // Set a prop node so we get past the first guard.
        await router.setOutboundPropagationNode(Data((0..<16).map { _ in 0xCD }))
        // setTransport - but transport not strictly needed since
        // we'll fail on the .notPacked guard first. Actually the
        // guard order is: propNode → transport → packed. Without
        // a transport, we hit transportNotAvailable instead. To
        // isolate the .notPacked guard we need a transport stub.
        let transport = ReticulumTransport()
        await router.setTransport(transport)

        var msg = LXMessage(
            destinationHash: Data((0..<16).map { _ in 0xAB }),
            sourceIdentity: Identity(),
            content: Data("test".utf8),
            title: Data(), fields: nil, desiredMethod: .propagated
        )
        // Skip the .pack() call — that's the bug under test (caller
        // forgot to pack before sending).

        do {
            try await router.sendPropagated(&msg)
            XCTFail("sendPropagated must throw when message is not packed")
        } catch LXMFError.notPacked {
            // expected
        } catch {
            XCTFail("expected notPacked, got \(error)")
        }
    }

    func testSendDirectThrowsWhenTransportNotAvailable() async throws {
        let router = try await makeRouter()
        // Don't setTransport — that's the guard under test.

        var msg = LXMessage(
            destinationHash: Data((0..<16).map { _ in 0xAB }),
            sourceIdentity: Identity(),
            content: Data("test".utf8),
            title: Data(), fields: nil, desiredMethod: .direct
        )
        _ = try msg.pack()

        do {
            try await router.sendDirect(&msg)
            XCTFail("sendDirect must throw when transport not set")
        } catch LXMFError.linkFailed {
            // expected — sendDirect wraps `transportNotAvailable` via
            // the static `LXMFError.transportNotAvailable` which is
            // itself a `.linkFailed("Transport not available")`.
        } catch {
            XCTFail("expected linkFailed/transportNotAvailable, got \(error)")
        }
    }

    func testSendDirectThrowsWhenMessageNotPacked() async throws {
        let router = try await makeRouter()
        let transport = ReticulumTransport()
        await router.setTransport(transport)

        var msg = LXMessage(
            destinationHash: Data((0..<16).map { _ in 0xAB }),
            sourceIdentity: Identity(),
            content: Data("test".utf8),
            title: Data(), fields: nil, desiredMethod: .direct
        )
        // Don't pack.

        do {
            try await router.sendDirect(&msg)
            XCTFail("sendDirect must throw when message not packed")
        } catch LXMFError.notPacked {
            // expected
        } catch {
            XCTFail("expected notPacked, got \(error)")
        }
    }

    func testSendOpportunisticThrowsWhenTransportNotAvailable() async throws {
        let router = try await makeRouter()

        var msg = LXMessage(
            destinationHash: Data((0..<16).map { _ in 0xAB }),
            sourceIdentity: Identity(),
            content: Data("test".utf8),
            title: Data(), fields: nil, desiredMethod: .opportunistic
        )
        _ = try msg.pack()

        do {
            try await router.sendOpportunistic(&msg)
            XCTFail("sendOpportunistic must throw when transport not set")
        } catch LXMFError.linkFailed {
            // expected. `LXMFError.transportNotAvailable` is a static
            // let aliasing `.linkFailed("Transport not available")`,
            // so the runtime case is `.linkFailed`.
        } catch {
            XCTFail("expected linkFailed/transportNotAvailable, got \(error)")
        }
    }

    func testHandleResourceTransferCompleteNoOpOnUnknownHash() async throws {
        // Defensive: if RESOURCE_PRF fires twice (re-delivery) or for a
        // hash that's already been cleared, the early-return must not
        // crash and must not mutate unrelated map entries.
        let router = try await makeRouter()

        let stableHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let stableMsgHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.setPendingResourceDelivery(resourceHash: stableHash, messageHash: stableMsgHash)

        let unknownHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.handleResourceTransferComplete(resourceHash: unknownHash)

        let stillThere = await router.pendingResourceDeliveries[stableHash]
        XCTAssertEqual(stillThere, stableMsgHash,
            "Unknown-hash complete must not touch unrelated map entries.")
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

    /// Persist a packed LXMessage via the router's internal `database`
    /// so subsequent `handleOutboundResourceFailed` can load it back
    /// during re-enqueue. `database` was bumped from `private` to
    /// `internal` (LXMRouter.swift:67) specifically to enable
    /// `@testable`-scoped access here — production callers continue
    /// to go through the public `handleOutbound` / `lxmfDelivery`
    /// surface that already routes saves through `database` itself.
    fileprivate func testSaveMessage(_ message: LXMessage) async throws {
        try await database.saveMessage(message)
    }

    /// Read a message from the router's database by hash. Used by
    /// state-transition tests to verify async DB writes from
    /// `handlePropagationAccepted` / `handleResourceTransferComplete`
    /// took effect.
    fileprivate func testGetMessage(id: Data) async throws -> LXMessage? {
        try await database.getMessage(id: id)
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
