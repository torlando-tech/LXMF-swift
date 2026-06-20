// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterDeliveryTests.swift
//  LXMFSwiftTests
//
//  Tests for LXMRouter.lxmfDelivery(method:) classification.
//
//  These tests pin the recent fix that lets callers tell the router which
//  delivery method actually carried an inbound message. Before the fix,
//  every accepted message was persisted with method = .direct because that
//  is what `LXMessage.unpackFromBytes` defaults to. Callers in
//  LXMRouter+Destinations / LXMRouter+Sync now pass the correct method, and
//  this file verifies the wiring end-to-end (delivery -> DB).
//
//  Reference: Sources/LXMFSwift/Router/LXMRouter.swift `lxmfDelivery(_:physicalStats:method:)`.
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMRouterDeliveryTests: XCTestCase {

    // MARK: - Helpers

    /// Build a router backed by a unique temp-file DB. WAL mode requires a
    /// file on disk; `:memory:` is not usable here.
    private func makeRouter(identity: Identity) async throws -> (LXMRouter, String) {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-router-delivery-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: dbPath)
        }
        let router = try await LXMRouter(identity: identity, databasePath: dbPath)
        return (router, dbPath)
    }

    /// Pack an LXMF message addressed to `recipient`'s LXMF delivery destination,
    /// signed by `source`. Each call uses fresh content so the resulting hash
    /// is unique (the router's duplicate-cache rejects repeats by hash).
    private func makePackedMessage(
        from source: Identity,
        to recipient: Identity,
        content: String
    ) throws -> (packed: Data, hash: Data) {
        let recipientDeliveryHash = Destination.hash(
            identity: recipient,
            appName: "lxmf",
            aspects: ["delivery"]
        )
        var message = LXMessage(
            destinationHash: recipientDeliveryHash,
            sourceIdentity: source,
            content: content.data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        let packed = try message.pack()
        return (packed, message.hash)
    }

    // MARK: - Tests

    /// Each value of LXDeliveryMethod passed to lxmfDelivery should land in the
    /// persisted message's `method` field. Without the fix, all three branches
    /// would store `.direct` (the unpack default).
    func testDeliveryMethodOverridesUnpackDefault() async throws {
        let routerIdentity = Identity()
        let sourceIdentity = Identity()
        let (router, dbPath) = try await makeRouter(identity: routerIdentity)
        let database = try LXMFDatabase(path: dbPath)

        // Cache the source identity so signature validation passes cleanly
        // (otherwise the message is accepted with unverifiedReason=.sourceUnknown,
        // which is fine for this test but noisy).
        await router.registerIdentity(sourceIdentity)

        let cases: [(LXDeliveryMethod, String)] = [
            (.opportunistic, "opportunistic body"),
            (.direct,        "direct body"),
            (.propagated,    "propagated body"),
        ]

        for (method, body) in cases {
            let (packed, hash) = try makePackedMessage(
                from: sourceIdentity,
                to: routerIdentity,
                content: body
            )

            let accepted = await router.lxmfDelivery(packed, method: method)
            XCTAssertTrue(accepted, "lxmfDelivery should accept message with method=\(method)")

            let saved = try await database.getMessage(id: hash)
            XCTAssertNotNil(saved, "Message with method=\(method) should be persisted")
            XCTAssertEqual(saved?.method, method,
                           "Persisted message method should equal the value passed to lxmfDelivery (got \(String(describing: saved?.method)), expected \(method))")
            XCTAssertTrue(saved?.incoming ?? false,
                          "Delivered message should be marked incoming")
        }
    }

    /// When `method:` is omitted, the router preserves whatever
    /// `LXMessage.unpackFromBytes` produced. Today that default is `.direct`.
    /// This test documents that legacy behavior so a future change to the
    /// unpack default surfaces here intentionally.
    func testDeliveryMethodNilPreservesUnpackDefault() async throws {
        let routerIdentity = Identity()
        let sourceIdentity = Identity()
        let (router, dbPath) = try await makeRouter(identity: routerIdentity)
        let database = try LXMFDatabase(path: dbPath)

        await router.registerIdentity(sourceIdentity)

        let (packed, hash) = try makePackedMessage(
            from: sourceIdentity,
            to: routerIdentity,
            content: "no method override"
        )

        let accepted = await router.lxmfDelivery(packed, method: nil)
        XCTAssertTrue(accepted, "lxmfDelivery should accept the message")

        let saved = try await database.getMessage(id: hash)
        XCTAssertNotNil(saved, "Message should be persisted")
        XCTAssertEqual(saved?.method, .direct,
                       "Without an override, persisted method should match the unpack default (.direct)")
    }

    /// The delivery-proof retry fix keeps a small-packet OPPORTUNISTIC/DIRECT message
    /// in `pendingOutbound` at `.sent` (awaiting its proof) and relies on
    /// `loadPendingOutbound` re-enqueuing it after an NE jetsam so it is re-sent and
    /// earns a fresh proof. This pins the reload filter's scoping: `.outbound`
    /// (never-sent) and OPPORTUNISTIC/DIRECT `.sent` reload, but a PROPAGATED `.sent`
    /// (terminal — the propagation node ack'd the upload, no recipient proof is
    /// expected) must NOT reload, else it would be re-uploaded on every launch.
    func testLoadPendingOutboundReloadScoping() async throws {
        let routerIdentity = Identity()
        let sourceIdentity = Identity()
        let (_, dbPath) = try await makeRouter(identity: routerIdentity)
        let database = try LXMFDatabase(path: dbPath)

        func persist(_ method: LXDeliveryMethod, _ state: LXMessageState, _ body: String) async throws -> Data {
            var msg = LXMessage(
                destinationHash: Destination.hash(identity: routerIdentity, appName: "lxmf", aspects: ["delivery"]),
                sourceIdentity: sourceIdentity,
                content: body.data(using: .utf8)!,
                title: Data(),
                fields: nil,
                desiredMethod: method
            )
            _ = try msg.pack()          // stamps a stable, unique hash (content differs per call)
            msg.method = method
            msg.state = state
            try await database.saveMessage(msg)
            return msg.hash
        }

        let outboundHash   = try await persist(.direct,        .outbound, "never-sent direct")
        let sentDirectHash = try await persist(.direct,        .sent,     "sent direct awaiting proof")
        let sentOppHash    = try await persist(.opportunistic, .sent,     "sent opp awaiting proof")
        let sentPropHash   = try await persist(.propagated,    .sent,     "propagated terminal sent")

        let reloaded = Set(try await database.loadPendingOutbound().map { $0.hash })

        XCTAssertTrue(reloaded.contains(outboundHash),   ".outbound (never-sent) must reload")
        XCTAssertTrue(reloaded.contains(sentDirectHash), "DIRECT .sent must reload for retry-until-delivered")
        XCTAssertTrue(reloaded.contains(sentOppHash),    "opportunistic .sent must reload for retry-until-delivered")
        XCTAssertFalse(reloaded.contains(sentPropHash),  "PROPAGATED .sent is terminal — must NOT reload (would re-upload)")
    }
}
