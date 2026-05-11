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

        // Resolve recipient identity. Order matters:
        //
        //  1. If the destination matches one of OUR registered local
        //     LXMF delivery destinations, use that destination's identity
        //     directly. This mirrors python `RNS.Identity.recall(hash)`,
        //     which returns the local identity for own destinations
        //     without consulting Transport's path table. Concretely: a
        //     phone sending to one of its own LXMF destinations (the
        //     test-harness self-loop pattern, also legitimate scenarios
        //     like sending to a secondary identity) wouldn't have a
        //     PathTable entry for itself — announces leave the device,
        //     they don't loop back into the local table — so the
        //     pathTable.lookup below would fail with .noPath even though
        //     we obviously DO know our own keys.
        //
        //  2. Otherwise look up the path table for received-announce
        //     entries. This is the normal cross-device case.
        //
        // The kotlin port (LXMF-kt LXMRouter.kt:1181-1183) avoids this
        // problem by passing the recipient `Destination` object directly
        // on the LXMessage at creation, with keys already attached.
        // LXMF-swift's API takes a bare destinationHash, so the lookup
        // happens here — and needs both branches.
        let destIdentity: Identity
        let destIdentityHash: Data
        if let localDest = deliveryDestinations[Data(destHash)]?.0,
           let localIdentity = localDest.identity {
            destIdentity = localIdentity
            destIdentityHash = localIdentity.hash
            propLogger.info("[PROP_SEND] Resolving \(destHashHex) via local delivery destination")
        } else {
            guard let pathTable = self.pathTable else {
                throw LXMFError.transportNotAvailable
            }
            guard let destPathEntry = await pathTable.lookup(destinationHash: Data(destHash)) else {
                propLogger.error("[PROP_SEND] No path entry for recipient \(destHashHex); LXMessage cannot be encrypted to recipient")
                throw LXMFError.noPath
            }
            destIdentity = try Identity(publicKeyBytes: destPathEntry.publicKeys)
            destIdentityHash = destIdentity.hash
        }

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
            propLogger.info("[PROP_SEND_STAMP] cost=\(stampCost) rounds=\(rounds) lxmData_len=\(lxmData.count) tid=\(transientId.prefix(8).map { String(format: "%02x", $0) }.joined()) stamp=\(stampBytes.prefix(8).map { String(format: "%02x", $0) }.joined())")
        } else {
            // Cost 0: any stamp passes, but still needs proper format (32 bytes)
            stampBytes = Data((0..<LXStamper.STAMP_SIZE).map { _ in UInt8.random(in: 0...255) })
            propLogger.warning("[PROP_SEND_STAMP] cost=0 — sending RANDOM stamp; lxmd will likely reject if it requires non-zero cost")
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

        // Do NOT identify on the delivery link.
        //
        // Python `LXMRouter.process_outbound` PROPAGATED branch (LXMRouter.py
        // 2682-2720) deliberately omits `link.identify()`. Only the sync /
        // retrieval path (LXMRouter.py:494) identifies. Identifying on the
        // delivery link forces lxmd's `propagation_resource_concluded`
        // (LXMRouter.py:2191) into the peer-discovery branch — calling
        // `recall_app_data(remote_hash)` while the resource is concluding —
        // which probes global state during the proof emission path and
        // stalls the proof. The kotlin port hit and documented the same
        // trap (LXMF-kt LXMRouter.kt:2181-2206). Symptom: state stuck at
        // .sending, no proof callback, no delegate notify.
        message.state = .sending
        notifyUpdate(message)

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

            try await transport.sendLinkData(packet: packet)

            // Wait for proof from propagation node (confirms message accepted)
            let proved = await transport.waitForPacketProof(packetHash: packetHash, timeout: 15)
            if proved {
                // Python `__mark_propagated` flips state to SENT (LXMessage.py:570).
                message.state = .sent
                notifyUpdate(message)
            } else {
                // Python `__link_packet_timed_out` (LXMessage.py:611-616)
                // flips state back to OUTBOUND so processOutbound can retry.
                // Previously the swift port marked .sent unconditionally,
                // which was a silent ack of failure.
                message.state = .outbound
                notifyUpdate(message)
                throw LXMFError.propagationFailed("propagation link-packet proof timeout")
            }
        } else {
            // Large message: use Resource transfer.
            //
            // Mirrors the sendDirect resource path (LXMRouter+Delivery.swift:
            // 304-326). The completion callback is what flips state to .sent
            // and notifies the delegate — emitting it inline immediately
            // after `sendResource` returns is wrong because that's just the
            // advertisement, not lxmd's ack. Without the callback wiring,
            // outbound PROPAGATED state would never advance for any message
            // that needs Resource (most messages, given LXMF_OVERHEAD pushes
            // size over 431 bytes).
            //
            // Python ref: LXMessage.py:649-651 wires
            //   RNS.Resource(propagation_packed, link,
            //                callback=__propagation_resource_concluded,
            //                progress_callback=__update_transfer_progress)
            // and __propagation_resource_concluded → __mark_propagated → SENT.
            let outboundHandler = LXMFOutboundResourceHandler(router: self)
            await link.setResourceCallbacks(outboundHandler)

            let resource = try await link.sendResource(
                data: propagationPayload, requestId: nil, isResponse: false
            )

            if let resHash = await resource.hash {
                pendingResourceDeliveries[resHash] = message.hash
                // Tag this resource as a PROPAGATED upload. When RESOURCE_PRF
                // arrives, `handleResourceTransferComplete` consults this set
                // and routes to `handlePropagationAccepted` (state → .sent)
                // rather than `handleDeliveryProofReceived` (state →
                // .delivered). Python ref: `LXMessage.__as_resource`
                // (LXMF/LXMessage.py:649-651) wires
                // `__propagation_resource_concluded` for the prop path,
                // distinct from `__resource_concluded` for direct.
                pendingPropagationResources.insert(resHash)
                let resHashHex = resHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                let msgHashHex = message.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
                propLogger.info(
                    "PROPAGATED resource registered \(resHashHex) → message \(msgHashHex); awaiting RESOURCE_PRF"
                )
            } else {
                // Couldn't register for proof tracking — without the resHash
                // we can't map RESOURCE_PRF back to this message. Throw so
                // processOutbound's retry path runs rather than leaving the
                // message in .sending forever.
                message.state = .outbound
                notifyUpdate(message)
                throw LXMFError.propagationFailed("propagation resource has no hash; cannot wire proof callback")
            }
            // NOTE: state stays .sending here. handleResourceTransferComplete
            // routes via handlePropagationAccepted to flip state → .sent
            // when RESOURCE_PRF arrives (python ref: __mark_propagated).
        }
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

        // Register a packet callback for propagation-link signaling.
        //
        // Mirrors python `LXMRouter.process_outbound` PROPAGATED branch:
        //   self.outbound_propagation_link.set_packet_callback(
        //       self.propagation_transfer_signalling_packet)
        // (LXMRouter.py:2719). The handler at LXMRouter.py:2498 unpacks
        // msgpack data and reacts to LXMPeer.ERROR_INVALID_STAMP (0xf5).
        //
        // WITHOUT this callback, lxmd's signaling packets get routed
        // through Transport's default link-data path (ReticulumTransport
        // .swift:2167) which checks `plaintext.count >= 16` for an LXMF
        // dest hash — signaling msgpack arrays are typically a few bytes,
        // so they fail the check, fall through, and Transport logs
        // "Link data too short for LXMF" and DROPS them. lxmd sees no
        // response, gives up, closes the link with `closed by remote
        // peer (verified)`. Net effect: every PROPAGATED send hangs
        // through the full LINK_TIMEOUT (30s) and retries indefinitely.
        //
        // This was the proximate cause of iOS issue #67.
        await link.setPacketCallback { [weak self] data, _ in
            guard let self = self else { return }
            await self.handlePropagationSignalingPacket(data, link: link)
        }

        propLogger.error("[PROP_LINK] Link initiated, waiting for active state...")

        // Wait for link to become active
        try await waitForPropagationLinkActive(link, timeout: PropagationConstants.LINK_TIMEOUT)

        return link
    }

    /// Handle a signaling packet received over the propagation link's
    /// packet-callback channel. Mirrors python
    /// `LXMRouter.propagation_transfer_signalling_packet`
    /// (LXMRouter.py:2498-2511).
    ///
    /// Format: msgpack-encoded `[code, ...]` where `code` is one of
    /// `PropagationConstants.ERROR_INVALID_STAMP` (currently the only
    /// signal python sends; future-proofed by leaving the array open).
    ///
    /// On `ERROR_INVALID_STAMP` the python reference cancels the
    /// outbound message via `cancel_outbound(message_id, REJECTED)`.
    /// LXMF-swift exposes the equivalent transition by setting the
    /// pending outbound message's state to `.rejected` and removing it
    /// from `pendingOutbound`. The `for_lxmessage` association python
    /// uses (LXMRouter.py:2505-2506) maps to the (link → message)
    /// pairing established at send time; with the current LXMF-swift
    /// design the single most-recent `pendingOutbound` entry routed
    /// through this propagation node is the most likely target. We
    /// scan `pendingOutbound` for the topmost message that's
    /// `.propagated` AND `.sending` and reject that one.
    func handlePropagationSignalingPacket(_ data: Data, link: Link) async {
        do {
            let unpacked = try unpackLXMF(data)
            guard case .array(let elements) = unpacked,
                  let first = elements.first else {
                propLogger.warning("[PROP_SIGNAL] payload not a non-empty array — ignoring")
                return
            }
            // Codes are sent as msgpack uint by python.
            let code: UInt8
            switch first {
            case .uint(let u): code = UInt8(truncatingIfNeeded: u)
            case .int(let i):  code = UInt8(truncatingIfNeeded: i)
            default:
                propLogger.warning("[PROP_SIGNAL] first element not a numeric code — ignoring")
                return
            }
            switch code {
            case PropagationConstants.ERROR_INVALID_STAMP:
                propLogger.error("[PROP_SIGNAL] ERROR_INVALID_STAMP — propagation node rejected outbound stamp")
                // Best-effort match-and-reject of the most recently-sent
                // PROPAGATED message that's still in flight.
                for i in pendingOutbound.indices.reversed() {
                    var msg = pendingOutbound[i]
                    if msg.method == .propagated && msg.state == .sending {
                        msg.state = .rejected
                        pendingOutbound[i] = msg
                        // Persist the terminal `.rejected` state to the
                        // DB so a background-fetch / app-re-launch
                        // consumer sees the same outcome the UI does.
                        // Greptile review (4/5 confidence) flagged the
                        // earlier in-memory-only flip as a parity gap:
                        // python's terminal-state handlers (e.g.
                        // LXMessage.py:597 setting REJECTED) update
                        // the LXMessage object that's already the DB-
                        // backing source-of-truth, so persistence is
                        // implicit. Swift's separate in-memory queue +
                        // SQLite DB means we must write explicitly.
                        let msgHash = msg.hash
                        // ORDERING NOTE — awaited (not detached) on
                        // purpose. The other PROPAGATED-path DB writes
                        // (`.outbound` in processOutbound,
                        // `.sent` in handlePropagationAccepted) are
                        // also awaited inside the actor; a detached
                        // write here would land on the global executor
                        // outside the actor's mailbox and could
                        // interleave with a subsequent `processOutbound`
                        // tick or a fast `handlePropagationAccepted`,
                        // leaving the DB in the wrong terminal state
                        // (`.outbound` overwriting `.rejected`, or vice
                        // versa). See port-deviations.md sub-deviation
                        // "PROPAGATED resource path DB write ORDERING".
                        try? await database.updateMessageState(id: msgHash, state: .rejected)
                        notifyFailure(msg, reason: .stampValidationFailed)
                        let hashHex = msg.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
                        propLogger.error("[PROP_SIGNAL] cancelled outbound \(hashHex) as REJECTED (DB updated)")
                        return
                    }
                }
                propLogger.warning("[PROP_SIGNAL] ERROR_INVALID_STAMP received but no pending propagated message in .sending found")
            default:
                propLogger.warning("[PROP_SIGNAL] unknown signal code 0x\(String(format: "%02x", code))")
            }
        } catch {
            propLogger.error("[PROP_SIGNAL] msgpack decode failed: \(error.localizedDescription)")
        }
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
