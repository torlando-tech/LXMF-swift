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

    /// A link DATA packet to feed `sendLinkDataWithProofCallback`. The
    /// helper does not inspect packet contents — only the truncated
    /// hash matters for the proof-callback key — so any plausibly-
    /// shaped link packet is fine.
    private func makeLinkPacket() -> Packet {
        let header = PacketHeader(
            headerType: .header1,
            hasContext: false,
            transportType: .broadcast,
            destinationType: .link,
            packetType: .data,
            hopCount: 0
        )
        let linkId = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
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
        let router = try await makeRouter()
        let transport = ReticulumTransport()
        let mock = CapturingInterface(id: "proof-cb-success")
        try await transport.addInterface(mock)
        await router.setTransport(transport)

        let packet = makeLinkPacket()
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        try await router.sendLinkDataWithProofCallback(
            packet: packet,
            destinationHash: packet.destination,
            messageHash: messageHash,
            transport: transport
        )

        let sent = await mock.drain()
        XCTAssertGreaterThanOrEqual(sent.count, 1,
            "Expected at least one outbound packet on the mock " +
            "interface; got \(sent.count). Helper either short-" +
            "circuited the send or the mock isn't wired into the " +
            "transport's send loop.")
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
        let router = try await makeRouter()
        let transport = ReticulumTransport()
        let mock = ThrowingInterface(id: "proof-cb-error")
        try await transport.addInterface(mock)
        await router.setTransport(transport)

        let packet = makeLinkPacket()
        let messageHash = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        do {
            try await router.sendLinkDataWithProofCallback(
                packet: packet,
                destinationHash: packet.destination,
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
