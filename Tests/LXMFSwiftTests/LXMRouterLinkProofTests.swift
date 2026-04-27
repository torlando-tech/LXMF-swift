// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterLinkProofTests.swift
//  LXMFSwiftTests
//
//  Pins the link-context delivery proof routing in
//  `LXMRouter.deliveryPacket` (via `sendDeliveryProof`). For
//  destinations of type `.link` the router must call
//  `Link.provePacket(_:)` so the proof carries explicit-format data
//  (32-byte hash + 64-byte signature) addressed to the link itself —
//  the only shape `RNS.PacketReceipt.validate_link_proof` accepts on
//  the python sender side. Without this branch, swift would fall
//  back to a SINGLE-implicit proof and DIRECT outbound on the python
//  side would never advance to `delivered`.
//
//  Reference:
//    Sources/LXMFSwift/Router/LXMRouter+Destinations.swift
//    sendDeliveryProof — `if packet.header.destinationType == .link`.
//

#if DEBUG  // Uses ReticulumSwift's `_setStateForTesting` (DEBUG-only).
import XCTest
@testable import LXMFSwift
@testable import ReticulumSwift
import CryptoKit

final class LXMRouterLinkProofTests: XCTestCase {

    /// End-to-end pin for the link-context proof branch.
    ///
    /// Builds a responder Link, registers it with the transport, drives
    /// `deliveryPacket` with a link-DATA packet, and asserts the bytes
    /// captured on the link's sendCallback decode to a PROOF whose
    /// destinationType is `.link` and whose destination matches the
    /// linkId. A regression on the link branch (e.g. routing back
    /// through the SINGLE-implicit `transport.send(packet:)` path)
    /// would surface here as either no captured packet at all or a
    /// SINGLE/IMPLICIT proof shape.
    func testDeliveryPacketRoutesLinkProofThroughLinkProvePacket() async throws {
        let identity = Identity()
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-link-proof-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        let router = try await LXMRouter(identity: identity, databasePath: dbPath)

        let transport = ReticulumTransport()
        await router.setTransport(transport)

        // Build a responder Link addressed to a registered destination
        // and force it `.active` (the LRRTT handshake doesn't matter
        // for proof wire format — we just need `state.isEstablished`
        // and `sendCallback` set so `provePacket` will emit bytes).
        let dest = Destination(identity: identity, appName: "lxmf", aspects: ["delivery"])
        let encKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let sigKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let signaling = IncomingLinkRequest.encodeSignaling(
            mtu: 500, mode: LinkConstants.MODE_DEFAULT
        )
        var requestData = Data()
        requestData.append(encKey)
        requestData.append(sigKey)
        requestData.append(signaling)
        let lrHeader = PacketHeader(
            headerType: .header1,
            hasContext: false,
            transportType: .broadcast,
            destinationType: .single,
            packetType: .linkRequest,
            hopCount: 0
        )
        let lrPacket = Packet(
            header: lrHeader,
            destination: dest.hash,
            context: 0x00,
            data: requestData
        )
        let incomingRequest = try IncomingLinkRequest(data: requestData, packet: lrPacket)
        let link = Link(incomingRequest: incomingRequest, destination: dest, identity: identity)

        let captured = SendCallbackCapture()
        await link.setSendCallback { data in await captured.append(data) }
        await link._setStateForTesting(.active)
        await transport.registerLink(link)

        // Build a link-DATA packet — this is what `deliveryPacket`
        // sees on the inbound path for a DIRECT message that fits in
        // a single packet. The body content doesn't matter for proof
        // generation (proofs are over `getFullHash()` of the packet
        // header + data, not the decrypted plaintext).
        let dataHeader = PacketHeader(
            headerType: .header1,
            hasContext: false,
            transportType: .broadcast,
            destinationType: .link,
            packetType: .data,
            hopCount: 0
        )
        let linkId = await link.linkId
        let inboundDataPacket = Packet(
            header: dataHeader,
            destination: linkId,
            context: 0x00,
            data: Data("ciphertext-stand-in".utf8)
        )

        // ---- Act: drive the LXMF inbound path -----------------------
        // `deliveryPacket(data, packet)` is the public entry the
        // transport callback chain invokes. It calls
        // `sendDeliveryProof(for:)` which (post-fix) routes link
        // packets through `link.provePacket(_:)`.
        await router.deliveryPacket(inboundDataPacket.data, inboundDataPacket)

        // ---- Assert: link saw exactly one outbound proof packet ------
        let sent = await captured.drain()
        XCTAssertEqual(sent.count, 1,
            "Expected exactly one outbound packet on the link's " +
            "sendCallback (the delivery proof). Got \(sent.count). " +
            "If 0, sendDeliveryProof regressed to skipping the link " +
            "branch; if >1, something is double-emitting.")

        let raw = try XCTUnwrap(sent.first)
        let proof = try Packet(from: raw)
        XCTAssertEqual(proof.header.packetType, .proof,
            "Outbound packet must be a PROOF.")
        XCTAssertEqual(proof.header.destinationType, .link,
            "Link-context proof must use destinationType=LINK so " +
            "python's `validate_proof_packet` routes it to the link " +
            "lookup path.")
        XCTAssertEqual(proof.destination, linkId,
            "Proof destination must be the linkId.")
        XCTAssertEqual(proof.data.count, 96,
            "Explicit link proof is 32-byte hash + 64-byte signature " +
            "= 96 bytes; got \(proof.data.count).")

        // The proof hash must match the inbound packet's full hash —
        // sender's PacketReceipt is keyed on this.
        let proofHash = Data(proof.data.prefix(32))
        XCTAssertEqual(proofHash, inboundDataPacket.getFullHash(),
            "Proof's first 32 bytes must equal the inbound packet's " +
            "fullHash; otherwise the python sender's receipt won't match.")
    }
}

/// Sendable storage for sendCallback-captured bytes (mirrors the
/// `CapturedSends` helper in reticulum-swift's LinkProveTests).
private actor SendCallbackCapture {
    private var packets: [Data] = []

    func append(_ data: Data) {
        packets.append(data)
    }

    func drain() -> [Data] {
        let copy = packets
        packets = []
        return copy
    }
}
#endif
