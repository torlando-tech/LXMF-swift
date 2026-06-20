// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterLinkCloseTests.swift
//  LXMFSwiftTests
//
//  Tests for `handleLinkUnexpectedClose` (issue #10b): the swift port of python's
//  process_outbound CLOSED branch (LXMRouter.py:2628-2647). When a DIRECT delivery link
//  closes unexpectedly while a small-packet message is in flight, the handler reverts the
//  in-flight `.sent` message to `.outbound` so the next processOutbound pass re-sends it.
//  These pin the three non-trivial correctness properties: the linkId identity guard, the
//  `.sent`-only revert (which also serves as the proof-landed re-check), and that a
//  `.delivered` message is never reverted.
//

import XCTest
import CryptoKit
import ReticulumSwift
@testable import LXMFSwift

final class LXMRouterLinkCloseTests: XCTestCase {

    // MARK: - Helpers

    private func makeRouter() async throws -> LXMRouter {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-linkclose-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        return try await LXMRouter(identity: Identity(), databasePath: dbPath)
    }

    /// Build a real (pending) `Link` and return it with its `linkId`. Mirrors the link
    /// construction in `LXMRouterProofCallbackTests.registerActiveLink`.
    private func makeLink() async throws -> (link: Link, linkId: Data) {
        let identity = Identity()
        let dest = Destination(identity: identity, appName: "test", aspects: ["link-close"])
        let encKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let sigKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let signaling = IncomingLinkRequest.encodeSignaling(mtu: 500, mode: LinkConstants.MODE_DEFAULT)
        var requestData = Data()
        requestData.append(encKey)
        requestData.append(sigKey)
        requestData.append(signaling)
        let header = PacketHeader(
            headerType: .header1, hasContext: false, transportType: .broadcast,
            destinationType: .single, packetType: .linkRequest, hopCount: 0
        )
        let lrPacket = Packet(header: header, destination: dest.hash, context: 0x00, data: requestData)
        let incoming = try IncomingLinkRequest(data: requestData, packet: lrPacket)
        let link = Link(incomingRequest: incoming, destination: dest, identity: identity)
        return (link, await link.linkId)
    }

    /// A packed outbound DIRECT message in the given state, addressed to `destHash`.
    private func makeDirectMessage(to destHash: Data, state: LXMessageState) throws -> LXMessage {
        var msg = LXMessage(
            destinationHash: destHash, sourceIdentity: Identity(),
            content: Data("hi".utf8), title: Data(), fields: nil, desiredMethod: .direct
        )
        _ = try msg.pack()   // stamps the hash
        msg.state = state
        return msg
    }

    private func lxmfDeliveryHash() -> Data {
        Destination.hash(identity: Identity(), appName: "lxmf", aspects: ["delivery"])
    }

    // MARK: - Tests

    /// Matching linkId + a `.sent` message → the handler reverts it to `.outbound`.
    func testUnexpectedCloseRevertsSentMessageWhenLinkIdMatches() async throws {
        let router = try await makeRouter()
        let (link, linkId) = try await makeLink()
        let destHash = lxmfDeliveryHash()
        await router._seedDeliveryLinkForTesting(link, destinationHash: destHash)
        let msg = try makeDirectMessage(to: destHash, state: .sent)
        await router._enqueuePendingForTesting(msg)

        await router.handleLinkUnexpectedClose(destinationHash: destHash, linkId: linkId, reason: .timeout)

        let state = await router._pendingStateForTesting(messageHash: msg.hash)
        XCTAssertEqual(state, .outbound,
                       "an unexpected close with a matching linkId must revert the in-flight .sent message to .outbound")
    }

    /// A STALE callback (linkId no longer matches the current delivery link) is a no-op — it
    /// must not clobber a message already re-sent over a newer link.
    func testUnexpectedCloseIsNoOpWhenLinkIdMismatches() async throws {
        let router = try await makeRouter()
        let (link, _) = try await makeLink()
        let destHash = lxmfDeliveryHash()
        await router._seedDeliveryLinkForTesting(link, destinationHash: destHash)
        let msg = try makeDirectMessage(to: destHash, state: .sent)
        await router._enqueuePendingForTesting(msg)

        let staleLinkId = Data(repeating: 0xAB, count: 16)
        await router.handleLinkUnexpectedClose(destinationHash: destHash, linkId: staleLinkId, reason: .timeout)

        let state = await router._pendingStateForTesting(messageHash: msg.hash)
        XCTAssertEqual(state, .sent,
                       "a stale-link callback (linkId mismatch) must NOT revert the message")
    }

    /// A `.delivered` message (proof won the race) is not reverted even with a matching linkId —
    /// the `.sent`-only predicate excludes it.
    func testUnexpectedCloseDoesNotRevertDeliveredMessage() async throws {
        let router = try await makeRouter()
        let (link, linkId) = try await makeLink()
        let destHash = lxmfDeliveryHash()
        await router._seedDeliveryLinkForTesting(link, destinationHash: destHash)
        let msg = try makeDirectMessage(to: destHash, state: .delivered)
        await router._enqueuePendingForTesting(msg)

        await router.handleLinkUnexpectedClose(destinationHash: destHash, linkId: linkId, reason: .timeout)

        let state = await router._pendingStateForTesting(messageHash: msg.hash)
        XCTAssertEqual(state, .delivered, "a delivered message must not be reverted by an unexpected close")
    }
}
