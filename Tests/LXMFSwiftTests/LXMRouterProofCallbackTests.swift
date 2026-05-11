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

    /// Stamp-rejection short-circuit: when the propagation node sent
    /// `ERROR_INVALID_STAMP` mid-resource-upload, the signal handler
    /// has already set `.rejected` in the DB and added the hash to
    /// `pendingPropagationRejections`. The subsequent resource
    /// conclusion (typically `.failed` from the link teardown) must
    /// route through the terminal path with `.rejected` preserved —
    /// NOT re-enqueue the message for retry, since the stamp config
    /// won't change and every retry would re-trigger the same
    /// rejection, spamming the delegate. And the duplicate
    /// `didFailMessage` must be suppressed (the signal handler
    /// already fired it with `.stampValidationFailed`).
    /// Python ref: `LXMessage.py:603-609` only guards against
    /// `state != CANCELLED`; swift needs this stronger guard because
    /// `handleOutboundResourceFailed` reloads from the DB and
    /// re-appends to `pendingOutbound` (a swift-specific
    /// accommodation already documented in port-deviations.md).
    func testOutboundResourceFailedShortCircuitsAfterStampRejection() async throws {
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("stamp-rejected-then-resource-fails".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)

        // Simulate post-signal state: DB already at .rejected (signal
        // handler wrote it), hash in pendingPropagationRejections,
        // resource maps still seeded (the resource was in-flight when
        // the signal arrived; conclusion fires after teardown).
        try await router.testUpdateMessageState(id: msg.hash, state: .rejected)
        await router.testInsertPendingPropagationRejection(msg.hash)
        let resourceHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        await router.setPendingResourceDelivery(resourceHash: resourceHash, messageHash: msg.hash)
        await router.markPendingPropagationResource(resourceHash: resourceHash)

        let recorder = await MainActor.run { FailureRecorder() }
        await router.setDelegate(recorder)

        // Resource conclusion fires with .failed (typical post-stamp-
        // rejection outcome — PN tore down the link).
        await router.handleOutboundResourceFailed(
            resourceHash: resourceHash, resourceState: .failed
        )

        // DB state must remain `.rejected` — the default propagation
        // branch would have overwritten with `.outbound`.
        let finalState = try await waitForMessageState(
            router, messageHash: msg.hash, expected: .rejected
        )
        XCTAssertEqual(finalState, .rejected,
            "Stamp-rejected message must retain `.rejected` in the DB. " +
            "Got \(String(describing: finalState)).")

        // Must NOT have been re-enqueued.
        let pendingHashes = await router.pendingOutbound.map { $0.hash }
        XCTAssertFalse(pendingHashes.contains(msg.hash),
            "Stamp-rejected message must NOT be re-enqueued for retry " +
            "(would cause infinite stamp-rejection loop until " +
            "MAX_DELIVERY_ATTEMPTS).")

        // Rejection-set entry must be drained.
        let stillInRejections = await router.testPendingPropagationRejectionsContains(msg.hash)
        XCTAssertFalse(stillInRejections,
            "Rejection-set entry must be drained after the resource " +
            "conclusion consumed it; otherwise the set leaks across " +
            "send attempts.")

        // Resource maps must be cleared (existing invariant).
        let afterProp = await router.pendingPropagationResources.count
        let afterDeliveries = await router.pendingResourceDeliveries.count
        XCTAssertEqual(afterProp, 0, "pendingPropagationResources must be reclaimed.")
        XCTAssertEqual(afterDeliveries, 0, "pendingResourceDeliveries must be reclaimed.")

        // Delegate must NOT receive a second notify — the signal
        // handler is responsible for the user-visible notification
        // with the accurate `.stampValidationFailed` reason. The
        // resource conclusion is a follow-on internal event.
        try await Task.sleep(nanoseconds: 100_000_000)
        let recorded = await MainActor.run { recorder.failures }
        XCTAssertEqual(recorded.count, 0,
            "Resource conclusion after stamp rejection must NOT fire " +
            "a duplicate didFailMessage — the signal handler already " +
            "notified the delegate with .stampValidationFailed.")
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

    /// `handleDeliveryProofReceived` is the DIRECT-path terminal
    /// handler — invoked when a delivery proof arrives (either as a
    /// PROOF packet for the small-packet path or as RESOURCE_PRF
    /// routed via `handleResourceTransferComplete` for the resource
    /// path). Per python `LXMessage.__mark_delivered`
    /// (LXMessage.py:556-566) it must transition the message to
    /// `.delivered`. Pin the async + awaited-DB-write behavior so the
    /// ordering guarantee against `processOutbound`'s in-flight
    /// `.outbound` write (DIRECT resource branch) is preserved.
    /// PR #7 round 6 — greptile 4/5 follow-up.
    func testHandleDeliveryProofReceivedTransitionsToDelivered() async throws {
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("direct-delivered".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)

        await router.handleDeliveryProofReceived(messageHash: msg.hash)

        let finalState = try await waitForMessageState(
            router, messageHash: msg.hash, expected: .delivered
        )
        XCTAssertEqual(finalState, .delivered,
            "handleDeliveryProofReceived must transition DB state to " +
            ".delivered per python LXMessage.py:556-566. Got " +
            "\(String(describing: finalState)).")
    }

    /// Ordering parity: when `processOutbound`'s DIRECT resource
    /// branch writes `.outbound` to the DB (the in-flight crash-
    /// recovery row), and then `handleDeliveryProofReceived` writes
    /// `.delivered` after the resource conclusion fires, the final
    /// DB row must be `.delivered` — NOT clobbered back to `.outbound`
    /// by a late-landing write. Without the actor-mailbox
    /// serialization (both writes `await`-ed inside the actor), a
    /// `Task.detached` from the conclusion callback could land on the
    /// global executor before the `processOutbound` write completed.
    /// This test sequences the two writes in the exact actor order
    /// they would fire and verifies the DB ends at `.delivered`.
    func testDirectResourcePathDBWriteOrdering() async throws {
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("direct-resource-ordering".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try msg.pack()
        // Simulate processOutbound's in-flight `.outbound` write
        // (full record via `saveMessage`, carrying deliveryAttempts).
        var outboundSnapshot = msg
        outboundSnapshot.state = .outbound
        try await router.testSaveMessage(outboundSnapshot)

        // Then the resource conclusion fires → DIRECT path →
        // handleDeliveryProofReceived writes `.delivered`. Both are
        // on the actor's serial mailbox, so this strict ordering
        // matches what real production code observes.
        await router.handleDeliveryProofReceived(messageHash: msg.hash)

        let finalState = try await waitForMessageState(
            router, messageHash: msg.hash, expected: .delivered
        )
        XCTAssertEqual(finalState, .delivered,
            "DIRECT resource ordering parity: after `.outbound` " +
            "in-flight write + `.delivered` conclusion write run in " +
            "actor order, the DB must reflect `.delivered`. " +
            "Got \(String(describing: finalState)). Regression here " +
            "means a `Task.detached` slipped back in somewhere.")
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

    // MARK: - send* happy-path coverage (with real Transport)
    //
    // The deep bodies of sendOpportunistic / sendDirect / sendPropagated
    // were originally only covered end-to-end via the cross-repo iOS
    // smoke suite. These tests stand up a real ReticulumTransport +
    // PathTable + MockInterface so the same code paths get unit-level
    // coverage rolled up to Codecov.
    //
    // Common setup pattern:
    //   1. Build router + transport + mock interface + wire them
    //   2. Generate a recipient Identity, compute its lxmf.delivery hash
    //   3. Seed PathTable with a PathEntry for that hash so the send's
    //      path-lookup succeeds
    //   4. Pack an LXMessage addressed to the recipient
    //   5. Invoke the send function
    //   6. Verify bytes landed on the mock interface

    /// Helper: build the lxmf.delivery destination hash for an Identity,
    /// matching what the receiver's LXMRouter would compute.
    private func lxmfDeliveryHash(for identity: Identity) -> Data {
        Destination.hash(identity: identity, appName: "lxmf", aspects: ["delivery"])
    }

    /// Helper: record a path entry in the transport's path table so
    /// `lookup(destinationHash:)` returns a valid entry for our recipient.
    private func seedPathEntry(
        transport: ReticulumTransport, destinationHash: Data, identity: Identity,
        hopCount: UInt8 = 1, interfaceId: String, nextHop: Data? = nil
    ) async {
        let pathTable = await transport.getPathTable()
        let entry = PathEntry(
            destinationHash: destinationHash,
            publicKeys: identity.publicKeys,
            interfaceId: interfaceId,
            hopCount: hopCount,
            expiration: 86400,
            randomBlob: Data((0..<10).map { _ in UInt8.random(in: 0...255) }),
            nextHop: nextHop
        )
        _ = await pathTable.record(entry: entry)
    }

    /// sendOpportunistic happy path: packs a single encrypted packet and
    /// sends through transport. Covers the identity-resolution + encrypt +
    /// packet-build + transport.send path. Roughly 30-40 lines of
    /// LXMRouter+Delivery.swift's `sendOpportunistic` body.
    func testSendOpportunisticHappyPathEmitsBytesOnInterface() async throws {
        let router = try await makeRouter()
        let transport = ReticulumTransport()
        let iface = CapturingInterface(id: "opp-happy-iface")
        try await transport.addInterface(iface)
        await router.setTransport(transport)

        let recipient = Identity()
        let destHash = lxmfDeliveryHash(for: recipient)
        await seedPathEntry(
            transport: transport, destinationHash: destHash, identity: recipient,
            interfaceId: iface.id
        )

        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: Identity(),
            content: Data("opp-happy".utf8),
            title: Data(), fields: nil, desiredMethod: .opportunistic
        )
        _ = try msg.pack()

        try await router.sendOpportunistic(&msg)

        let sent = await iface.drain()
        XCTAssertGreaterThanOrEqual(sent.count, 1,
            "sendOpportunistic happy path must emit at least one packet on " +
            "the mock interface; got \(sent.count). Either path lookup " +
            "failed (PathEntry seeded?) or transport routing skipped this " +
            "interface.")
    }

    // sendDirect / sendPropagated happy-path tests would require an
    // already-active Link to the recipient (DIRECT) or to the
    // propagation node (PROPAGATED). `Link._setStateForTesting`
    // (reticulum-swift) is internal to its own test target — there's
    // no public swift-API to force a link into `.active` state from
    // outside reticulum-swift's tests, and the real link-establish
    // handshake needs a counterparty. Coverage for those code paths
    // continues to live in the cross-repo iOS smoke suite
    // (`direct_echo` / `propagated_echo` in Columba's phone harness)
    // until reticulum-swift exposes a public test-state hook.

    // MARK: - Propagation signaling packet (ERROR_INVALID_STAMP)
    //
    // Regression coverage for the dead-code bug greptile flagged in
    // PR #7: the old `handlePropagationSignalingPacket` scanned
    // `pendingOutbound` for `state == .sending`, but that scan never
    // matched on either path:
    //   - Small-packet path: `processOutbound` writes the message back
    //     into `pendingOutbound[i]` only AFTER `sendPropagated` returns,
    //     so during the in-flight window `state` is still `.outbound`.
    //   - Resource path: `pendingOutbound[i] = msg` writeback runs
    //     synchronously then `indicesToRemove` removes the slot before
    //     the async signal can arrive.
    //
    // Fix wires the in-flight hash through `pendingPropagationSends`
    // (FIFO) at the top of `sendPropagated`, and the signal handler now
    // pops + persists `.rejected` + flips the pendingOutbound slot (if
    // still present). These tests pin the new behavior.

    /// Small-packet-style scenario: the message is still in
    /// `pendingOutbound` at `.outbound` (`processOutbound`'s post-call
    /// writeback hasn't run yet) when the signal arrives. Handler must:
    /// pop the hash from `pendingPropagationSends`, insert into
    /// `pendingPropagationRejections`, persist `.rejected` to the DB,
    /// flip the in-memory `pendingOutbound[i].state` to `.rejected`
    /// (so `processOutbound`'s `.rejected` guard removes it on the
    /// next tick without burning a retry slot), and fire
    /// `didFailMessage` with `.stampValidationFailed`.
    func testHandlePropagationSignalingPacketRejectsInFlightSmallPacket() async throws {
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("prop-stamp-rejected".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)
        await router.testAppendPendingOutbound(msg)
        await router.testAppendPendingPropagationSends(msg.hash)

        let recorder = await MainActor.run { FailureRecorder() }
        await router.setDelegate(recorder)

        // msgpack-encoded `[ERROR_INVALID_STAMP]` — same shape python's
        // peer sends back when the stamp check fails (python ref:
        // `LXMRouter.py:2131` — `msgpack.packb([LXMPeer.ERROR_INVALID_STAMP])`).
        let signal = packLXMF(.array([.uint(UInt64(PropagationConstants.ERROR_INVALID_STAMP))]))
        await router.handlePropagationSignalingPacket(signal)

        let finalState = try await waitForMessageState(
            router, messageHash: msg.hash, expected: .rejected
        )
        XCTAssertEqual(finalState, .rejected,
            "Signal handler must persist `.rejected` to the DB. " +
            "Got \(String(describing: finalState)).")

        let queueLen = await router.testPendingPropagationSendsCount
        XCTAssertEqual(queueLen, 0,
            "pendingPropagationSends FIFO must be drained after the " +
            "signal is consumed.")

        let rejectionsContains = await router.testPendingPropagationRejectionsContains(msg.hash)
        XCTAssertTrue(rejectionsContains,
            "pendingPropagationRejections must include the hash so the " +
            "small-packet `sendPropagated` post-wait check can pick it " +
            "up and throw `.rejected`.")

        let outboundState = await router.testPendingOutboundState(forHash: msg.hash)
        XCTAssertEqual(outboundState, .rejected,
            "pendingOutbound[i].state must be flipped to `.rejected` " +
            "so processOutbound's `.rejected` guard removes the slot " +
            "without burning a retry.")

        // Delegate callback dispatches on @MainActor — give it a beat.
        try await Task.sleep(nanoseconds: 100_000_000)
        let recorded = await MainActor.run { recorder.failures }
        XCTAssertEqual(recorded.count, 1,
            "Delegate must receive exactly one didFailMessage callback.")
        XCTAssertEqual(recorded.first?.hash, msg.hash,
            "didFailMessage must fire with the rejected message.")
        if case .stampValidationFailed = recorded.first?.reason {
            // expected
        } else {
            XCTFail("didFailMessage reason must be .stampValidationFailed; " +
                "got \(String(describing: recorded.first?.reason))")
        }
    }

    /// Resource-path scenario: the message has already been removed
    /// from `pendingOutbound` (resource path completes the
    /// `indicesToRemove` cleanup before RESOURCE_PRF or
    /// ERROR_INVALID_STAMP arrives). Handler must still: pop the hash,
    /// insert into rejections, persist `.rejected`, AND fire
    /// `didFailMessage` via a DB lookup fallback.
    func testHandlePropagationSignalingPacketRejectsInFlightResourcePath() async throws {
        let router = try await makeRouter()

        let srcIdentity = Identity()
        let destHash = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        var msg = LXMessage(
            destinationHash: destHash,
            sourceIdentity: srcIdentity,
            content: Data("prop-stamp-rejected-resource".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        _ = try msg.pack()
        try await router.testSaveMessage(msg)
        // Deliberately do NOT append to `pendingOutbound` — that
        // models the resource-path window between the
        // `pendingOutbound[i] = msg` writeback / `indicesToRemove`
        // cleanup and a stray ERROR_INVALID_STAMP arriving on the
        // propagation link's packet callback.
        await router.testAppendPendingPropagationSends(msg.hash)

        let recorder = await MainActor.run { FailureRecorder() }
        await router.setDelegate(recorder)

        let signal = packLXMF(.array([.uint(UInt64(PropagationConstants.ERROR_INVALID_STAMP))]))
        await router.handlePropagationSignalingPacket(signal)

        let finalState = try await waitForMessageState(
            router, messageHash: msg.hash, expected: .rejected
        )
        XCTAssertEqual(finalState, .rejected,
            "Resource-path: signal handler must still persist `.rejected` " +
            "even when the message has already left pendingOutbound. " +
            "Got \(String(describing: finalState)).")

        let queueLen = await router.testPendingPropagationSendsCount
        XCTAssertEqual(queueLen, 0, "FIFO must be drained.")

        try await Task.sleep(nanoseconds: 100_000_000)
        let recorded = await MainActor.run { recorder.failures }
        XCTAssertEqual(recorded.count, 1,
            "Delegate must receive one didFailMessage via the " +
            "DB-lookup fallback path even when pendingOutbound is empty.")
        XCTAssertEqual(recorded.first?.hash, msg.hash)
    }

    /// Defensive: signal arrives with no in-flight send. Must no-op
    /// (no DB mutation, no delegate call, no crash). Mirrors python's
    /// behavior when `packet.link.for_lxmessage` isn't set — the
    /// signal is logged and dropped.
    func testHandlePropagationSignalingPacketNoOpOnEmptyFIFO() async throws {
        let router = try await makeRouter()

        let recorder = await MainActor.run { FailureRecorder() }
        await router.setDelegate(recorder)

        let signal = packLXMF(.array([.uint(UInt64(PropagationConstants.ERROR_INVALID_STAMP))]))
        await router.handlePropagationSignalingPacket(signal)

        try await Task.sleep(nanoseconds: 100_000_000)
        let recorded = await MainActor.run { recorder.failures }
        XCTAssertEqual(recorded.count, 0,
            "Empty-FIFO signal must NOT fire didFailMessage.")
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

    /// Append a message hash to `pendingPropagationSends`. Mirrors what
    /// `sendPropagated` does at the top of its prop-path branch (FIFO
    /// push before any `await`), but exposed for tests that drive
    /// `handlePropagationSignalingPacket` directly without spinning up
    /// a real transport/link to call `sendPropagated`.
    fileprivate func testAppendPendingPropagationSends(_ hash: Data) {
        pendingPropagationSends.append(hash)
    }

    /// Append a message to the in-memory `pendingOutbound` queue —
    /// models the small-packet-path state where the slot still exists
    /// (`processOutbound`'s post-call writeback / `indicesToRemove`
    /// haven't run yet) when an `ERROR_INVALID_STAMP` arrives.
    fileprivate func testAppendPendingOutbound(_ message: LXMessage) {
        pendingOutbound.append(message)
    }

    /// Snapshot helpers for asserting on actor-isolated state. Returning
    /// scalar values avoids exposing the underlying collections via the
    /// `public` accessors that would normally trigger Sendable warnings.
    fileprivate var testPendingPropagationSendsCount: Int {
        pendingPropagationSends.count
    }

    fileprivate func testPendingPropagationRejectionsContains(_ hash: Data) -> Bool {
        pendingPropagationRejections.contains(hash)
    }

    fileprivate func testPendingOutboundState(forHash hash: Data) -> LXMessageState? {
        pendingOutbound.first(where: { $0.hash == hash })?.state
    }

    /// Seed a hash into `pendingPropagationRejections` — models the
    /// post-signal-handler state where the signal landed but the
    /// resource conclusion hasn't fired yet. Used by tests that
    /// exercise the stamp-rejection short-circuit in
    /// `handleOutboundResourceFailed`.
    fileprivate func testInsertPendingPropagationRejection(_ hash: Data) {
        pendingPropagationRejections.insert(hash)
    }

    /// Test-only DB state writer — mirrors what the signal handler
    /// does when it persists `.rejected`. Lets the resource-failure
    /// short-circuit test start from a realistic post-signal DB state
    /// without spinning up the real signal-handler path.
    fileprivate func testUpdateMessageState(id: Data, state: LXMessageState) async throws {
        try await database.updateMessageState(id: id, state: state)
    }
}

/// Records `didFailMessage` callbacks so the signal-handler tests can
/// assert the delegate is fired with the expected reason. Lives on
/// `@MainActor` because the delegate protocol requires it.
@MainActor
private final class FailureRecorder: LXMRouterDelegate {
    struct Failure {
        let hash: Data
        let reason: LXMFError
    }
    var failures: [Failure] = []
    nonisolated func router(_ router: LXMRouter, didFailMessage message: LXMessage, reason: LXMFError) {
        Task { @MainActor in
            failures.append(Failure(hash: message.hash, reason: reason))
        }
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
