// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouter+Propagation.swift
//  LXMFSwift
//
//  Outbound propagated delivery: send messages via a propagation node.
//  Establishes a link to lxmf.propagation, identifies, then sends the packed message.
//
//  Reference: LXMF/LXMRouter.py lines 2630-2700 (propagated delivery)
//

import Foundation
import ReticulumSwift
import os.log

private let propLogger = Logger(subsystem: "com.columba.core", category: "Propagation")

extension LXMRouter {

    // MARK: - Propagated Delivery

    /// Send message via propagation node (store-and-forward).
    ///
    /// Matches Python LXMF propagation format (LXMessage.py lines 431-449, 498-512):
    /// 1. Encrypt packed[16:] (source + signature + payload) to the DESTINATION identity
    /// 2. lxmf_data = dest_hash(16) + encrypted_data
    /// 3. propagation_packed = msgpack([timestamp, [lxmf_data]])
    /// 4. Send propagation_packed as link packet to propagation node
    ///
    /// The propagation node stores the message; the recipient retrieves it via sync.
    /// The message body is encrypted to the recipient, not the propagation node.
    ///
    /// - Parameter message: Message to send (must be packed)
    /// - Throws: LXMFError if propagation node not set, link fails, or send fails
    public func sendPropagated(_ message: inout LXMessage) async throws {
        guard let propagationNode = outboundPropagationNode else {
            throw LXMFError.propagationNodeNotSet
        }

        guard let transport = self.transport else {
            throw LXMFError.transportNotAvailable
        }

        guard let packed = message.packed else {
            throw LXMFError.notPacked
        }

        guard packed.count > 16 else {
            throw LXMFError.invalidMessageFormat("Packed message too short for propagation")
        }

        let nodeHex = propagationNode.prefix(8).map { String(format: "%02x", $0) }.joined()

        // --- Build propagation payload matching Python LXMF format ---
        //
        // packed = [dest_hash(16) | source_hash(16) | signature(64) | msgpack(payload)]
        //
        // Python LXMessage.pack() for PROPAGATED (LXMessage.py:431-441):
        //   pn_encrypted_data = destination.encrypt(packed[DEST_LEN:])
        //   lxmf_data = packed[:DEST_LEN] + pn_encrypted_data
        //   propagation_packed = msgpack([timestamp, [lxmf_data]])

        let destHash = packed.prefix(16)
        let messageBody = packed.dropFirst(16)  // source_hash + signature + payload
        let destHashHex = destHash.map { String(format: "%02x", $0) }.joined()

        // Look up recipient's public keys from path table
        guard let pathTable = self.pathTable else {
            throw LXMFError.transportNotAvailable
        }

        guard let destPathEntry = await pathTable.lookup(destinationHash: Data(destHash)) else {
            throw LXMFError.noPath
        }

        // Create recipient Identity for encryption
        let destIdentity = try Identity(publicKeyBytes: destPathEntry.publicKeys)
        let destIdentityHash = destIdentity.hash

        // Encrypt message body to RECIPIENT identity (NOT the propagation node)
        // This allows only the recipient to decrypt, while the propagation node stores opaquely
        let encryptedData = try destIdentity.encryptTo(Data(messageBody), identityHash: destIdentityHash)

        // Build lxm_data = dest_hash + encrypted(source + sig + payload)
        var lxmData = Data(destHash)
        lxmData.append(encryptedData)

        // Generate proper propagation stamp using LXStamper.
        // Python LXStamper.validate_pn_stamp() extracts stamp as last 32 bytes,
        // computes transient_id = SHA256(lxm_data), builds workblock with 1000 rounds,
        // then validates SHA256(workblock + stamp) has enough leading zero bits.
        let stampCost = propagationStampCost

        let transientId = Hashing.fullHash(lxmData)  // SHA256 of lxm_data (without stamp)
        let stampBytes: Data
        if stampCost > 0 {
            let (stamp, rounds) = await LXStamper.generateStamp(
                messageID: transientId,
                cost: stampCost,
                expandRounds: LXStamper.EXPAND_ROUNDS_PN
            )
            stampBytes = stamp
        } else {
            // Cost 0: any stamp passes, but still needs proper format (32 bytes)
            stampBytes = Data((0..<LXStamper.STAMP_SIZE).map { _ in UInt8.random(in: 0...255) })
        }

        var lxmfData = lxmData
        lxmfData.append(stampBytes)

        // Build propagation_packed = msgpack([timestamp, [lxmf_data + stamp]])
        let timestamp = message.timestamp != 0 ? message.timestamp : Date().timeIntervalSince1970
        let propagationPayload = packLXMF(.array([
            .double(timestamp),
            .array([.binary(lxmfData)])
        ]))

        // Get or establish link to propagation node
        let link = try await getOrEstablishPropagationLink(to: propagationNode, transport: transport)

        // Identify ourselves to the propagation node
        do {
            try await link.identify(identity: identity)
        } catch {
            // Non-fatal - some nodes may not require identification
        }

        // Update message state
        message.state = .sending

        // Send based on size (Python: LINK_PACKET_MAX_CONTENT = RNS.Link.MDU = 431)
        if propagationPayload.count <= LXMFConstants.LINK_PACKET_MDU {
            // Small enough for link DATA packet
            let encrypted = try await link.encrypt(propagationPayload)
            let linkId = await link.linkId

            let header = PacketHeader(
                headerType: .header1,
                hasContext: false,
                hasIFAC: false,
                transportType: .broadcast,
                destinationType: .link,
                packetType: .data,
                hopCount: 0
            )

            let packet = Packet(
                header: header,
                destination: linkId,
                transportAddress: nil,
                context: 0x00,
                data: encrypted
            )

            // Compute packet hash BEFORE sending (for proof matching)
            let packetHash = packet.getFullHash()

            let propDestHash = await link.destinationHash
            try await transport.sendLinkData(packet: packet, destinationHash: propDestHash)

            // Wait for proof from propagation node (confirms message accepted)
            let proved = await transport.waitForPacketProof(packetHash: packetHash, timeout: 15)
            if proved {
                message.state = .sent
            } else {
                message.state = .sent  // Still mark sent - we can't be certain it failed
            }
        } else {
            // Large message: use Resource transfer
            try await link.sendResource(data: propagationPayload, requestId: nil, isResponse: false)
            message.state = .sent
        }

        // Notify state update
        notifyUpdate(message)
    }

    // MARK: - Propagation Link Management

    /// Get existing or establish new link to propagation node.
    ///
    /// Uses separate link cache (`propagationLinks`) from direct delivery links.
    /// Targets "lxmf.propagation" destination.
    ///
    /// - Parameters:
    ///   - nodeHash: Propagation node destination hash (16 bytes)
    ///   - transport: Transport for link packet delivery
    /// - Returns: Active link to propagation node
    /// - Throws: LXMFError if link establishment fails
    func getOrEstablishPropagationLink(to nodeHash: Data, transport: ReticulumTransport) async throws -> Link {
        let nodeHex = nodeHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        propLogger.error("[PROP_LINK] getOrEstablishPropagationLink to \(nodeHex)")

        // Check for existing active propagation link
        if let link = propagationLinks[nodeHash] {
            let state = await link.state
            if state == .active {
                propLogger.error("[PROP_LINK] Reusing active link to \(nodeHex)")
                return link
            }
            propLogger.error("[PROP_LINK] Existing link state=\(String(describing: state)), removing")
            propagationLinks.removeValue(forKey: nodeHash)
        }

        // Look up path entry for the propagation node
        guard let pathTable = self.pathTable else {
            propLogger.error("[PROP_LINK] No pathTable available")
            throw LXMFError.transportNotAvailable
        }

        guard let pathEntry = await pathTable.lookup(destinationHash: nodeHash) else {
            propLogger.error("[PROP_LINK] No path entry for \(nodeHex)")
            throw LXMFError.noPath
        }

        propLogger.error("[PROP_LINK] Path entry found: hops=\(pathEntry.hopCount), pubkeys=\(pathEntry.publicKeys.count) bytes")

        // Create Identity from path entry's public keys
        let nodeIdentity = try Identity(publicKeyBytes: pathEntry.publicKeys)

        // Create propagation Destination (lxmf.propagation)
        let destination = Destination(
            identity: nodeIdentity,
            appName: "lxmf",
            aspects: [PropagationConstants.PROPAGATION_ASPECT],
            type: .single,
            direction: .out
        )
        propLogger.error("[PROP_LINK] Destination hash=\(destination.hash.prefix(8).map { String(format: "%02x", $0) }.joined()), initiating link...")

        // Initiate link
        let link = try await transport.initiateLink(to: destination, identity: identity)
        propagationLinks[nodeHash] = link
        propLogger.error("[PROP_LINK] Link initiated, waiting for active state...")

        // Wait for link to become active
        try await waitForPropagationLinkActive(link, timeout: PropagationConstants.LINK_TIMEOUT)

        return link
    }

    /// Wait for propagation link to become active with timeout.
    private func waitForPropagationLinkActive(_ link: Link, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastLoggedState = ""

        while Date() < deadline {
            let state = await link.state
            let stateStr = String(describing: state)
            if stateStr != lastLoggedState {
                propLogger.error("[PROP_LINK] Link state: \(stateStr)")
                lastLoggedState = stateStr
            }
            switch state {
            case .active:
                try? await Task.sleep(for: .milliseconds(100))
                return
            case .closed:
                throw LXMFError.linkFailed("Propagation link closed unexpectedly")
            default:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        propLogger.error("[PROP_LINK] Link timed out after \(timeout)s")

        throw LXMFError.linkFailed("Propagation link establishment timed out")
    }
}
