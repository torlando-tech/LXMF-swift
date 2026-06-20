// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouter+Delivery.swift
//  LXMFSwift
//
//  LXMF message delivery methods: opportunistic and direct.
//  Integrates with ReticulumTransport for packet sending and Link for direct delivery.
//
//  Reference: LXMF/LXMRouter.py lines 2496-2700
//

import Foundation
import CryptoKit
import ReticulumSwift
import os.log

private let directSendLogger = Logger(subsystem: "net.reticulum.lxmf", category: "DirectSend")
private let routerLogger = Logger(subsystem: "net.reticulum.lxmf", category: "LXMRouter")

// MARK: - Outbound Resource Handler

/// Resource callback handler for outbound LXMF direct delivery over links.
///
/// When a resource transfer completes (RESOURCE_PRF received from receiver),
/// maps the resource hash back to the LXMF message hash and marks it delivered.
/// This is what triggers the double checkmark in the UI.
///
/// Reference: Python LXMF/LXMRouter.py resource_concluded()
final class LXMFOutboundResourceHandler: ResourceCallbacks, @unchecked Sendable {
    private let router: LXMRouter

    init(router: LXMRouter) {
        self.router = router
    }

    func resourceConcluded(_ resource: Resource) async {
        let state = await resource.state
        guard let resourceHash = await resource.hash else {
            // No hash means we have no way to map back to the message.
            // Without a hash there's also nothing in the maps to leak.
            routerLogger.warning("Outbound resource concluded but no hash; map cleanup skipped (nothing to clean)")
            return
        }
        let resHex = resourceHash.prefix(8).map { String(format: "%02x", $0) }.joined()

        if state == .complete {
            routerLogger.info("Outbound resource \(resHex) transfer confirmed by receiver")
            await router.handleResourceTransferComplete(resourceHash: resourceHash)
        } else {
            // Non-complete terminal state (.failed, .rejected, .cancelled,
            // etc). Mirror python `LXMessage.__resource_concluded` /
            // `__propagation_resource_concluded` (LXMF/LXMessage.py:592-609):
            // unconditional dispatch on terminal state, branch by per-method
            // semantics inside `handleOutboundResourceFailed`. Critically,
            // the cleanup ALSO reclaims the swift-port-side map state
            // (pendingResourceDeliveries + pendingPropagationResources)
            // that the early-return predecessor leaked.
            routerLogger.warning("Outbound resource \(resHex) concluded in non-complete state \(String(describing: state)); marking message for retry / failure per python parity")
            await router.handleOutboundResourceFailed(
                resourceHash: resourceHash, resourceState: state
            )
        }
    }
}

/// LXMF message context byte for link packets
public enum LXMFContext {
    /// LXMF message context (value from Python: 0xF2)
    public static let message: UInt8 = 0xF2
}

extension LXMRouter {

    // MARK: - Transport Integration
    // Note: Transport property is added to LXMRouter actor in main file

    // MARK: - Opportunistic Delivery

    /// Send message via single packet (opportunistic delivery).
    ///
    /// For opportunistic delivery, the destination hash is in the packet header,
    /// and the data contains the encrypted payload using the recipient's public key.
    ///
    /// Encryption uses Reticulum's SINGLE destination pattern:
    /// 1. Look up recipient's encryption public key from path table
    /// 2. Generate ephemeral X25519 keypair
    /// 3. ECDH with recipient's public key
    /// 4. HKDF key derivation using destination hash as salt
    /// 5. Encrypt with Token (AES-256-CBC + HMAC-SHA256)
    ///
    /// - Parameter message: Message to send (must be packed)
    /// - Throws: LXMFError if transport not set, path not found, or send fails
    ///
    /// Reference: Python LXMRouter opportunistic send (lines 2600-2630)
    /// Reference: RNS Identity.encrypt() for SINGLE destination encryption
    public func sendOpportunistic(_ message: inout LXMessage) async throws {
        guard let transport = self.transport else {
            throw LXMFError.transportNotAvailable
        }

        guard let pathTable = self.pathTable else {
            throw LXMFError.transportNotAvailable
        }

        guard let packed = message.packed else {
            throw LXMFError.notPacked
        }

        // Resolve recipient encryption material. For self-send (own
        // delivery destinations), the path table has no entry — announces
        // leave the device, they don't loop back into the local table —
        // so we must check `deliveryDestinations` first. Mirrors python
        // `RNS.Identity.recall(hash)`'s "is this hash local?" branch.
        // Same pattern as `sendPropagated` — see LXMRouter+Propagation
        // for the full python ref discussion.
        let destHex = message.destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let effectiveKey: Data
        let pathRatchet: Data?
        let publicKeysForHash: Data
        if let localDest = deliveryDestinations[message.destinationHash]?.0,
           let localIdentity = localDest.identity {
            // Local destination: use its base key (no ratchet — that's
            // a per-recipient announce concept and we are the recipient).
            // `encryptionPublicKey` is a Curve25519 PublicKey type;
            // `publicKeys` is the wire-format Data (concat of enc + sign
            // public keys). For the HKDF salt and the SINGLE-destination
            // encrypt below, we want the raw Data form.
            effectiveKey = localIdentity.encryptionPublicKey.rawRepresentation
            pathRatchet = nil
            publicKeysForHash = localIdentity.publicKeys
            routerLogger.debug("OPP self-send: resolving \(destHex) via local delivery destination")
        } else {
            guard let pathEntry = await pathTable.lookup(destinationHash: message.destinationHash) else {
                throw LXMFError.destinationNotFound
            }
            // Get recipient's encryption public key (use ratchet if
            // available, otherwise base key). When a destination announces
            // with a ratchet, we MUST use the ratchet key for forward
            // secrecy.
            effectiveKey = pathEntry.effectiveEncryptionKey
            pathRatchet = pathEntry.ratchet
            publicKeysForHash = pathEntry.publicKeys
        }
        let hasRatchet = pathRatchet != nil && pathRatchet!.count == 32
        let keyHex = effectiveKey.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.debug("Using encryption key[0:8]=\(keyHex), hasRatchet=\(hasRatchet)")

        let recipientEncryptionPubKey: Curve25519.KeyAgreement.PublicKey
        do {
            recipientEncryptionPubKey = try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: effectiveKey
            )
        } catch {
            throw LXMFError.invalidMessageFormat("Invalid recipient encryption public key")
        }

        // CRITICAL: Python RNS uses identity hash as HKDF salt, NOT destination hash!
        // Identity hash = SHA256(publicKeys)[:16]
        // This must match Python RNS Identity.get_salt() which returns self.hash
        let identityHash = Hashing.truncatedHash(publicKeysForHash)
        let identityHashHex = identityHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.debug("Using identityHash[0:8]=\(identityHashHex) as HKDF salt")

        // For opportunistic: destination is in packet header, not data
        // Packed format: dest_hash (16) + source_hash (16) + signature (64) + msgpack
        // We skip first 16 bytes (dest_hash) since it's in packet header
        let plaintextData = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))

        // Encrypt data to recipient's public key using SINGLE destination encryption
        // Output format: [ephemeral_pub 32B][IV 16B][ciphertext][HMAC 32B]
        // NOTE: The HKDF salt is the IDENTITY hash (from public keys), NOT the destination hash!
        let encryptedData: Data
        do {
            encryptedData = try Identity.encrypt(
                plaintextData,
                to: recipientEncryptionPubKey,
                identityHash: identityHash  // Use identity hash as HKDF salt per Python RNS
            )
        } catch {
            throw LXMFError.encodingFailed("Encryption failed: \(error.localizedDescription)")
        }

        // Create packet with destination from message
        // Use BROADCAST transport type - the transport layer will convert to HEADER_2
        // if multi-hop routing is needed based on path table lookup
        let header = PacketHeader(
            headerType: .header1,           // Single address (destination)
            hasContext: false,               // No context byte for LXMF
            hasIFAC: false,                  // No interface access codes
            transportType: .broadcast,       // Broadcast to all interfaces (transport handles HEADER_2 conversion)
            destinationType: .single,        // Encrypted single destination
            packetType: .data,               // Application data
            hopCount: 0                      // Start at 0 hops
        )

        let packet = Packet(
            header: header,
            destination: message.destinationHash,
            transportAddress: nil,           // No transport address for HEADER_1
            context: 0x00,
            data: encryptedData              // Encrypted payload
        )

        // Update message state
        message.state = .sending

        // Register proof callback BEFORE sending to avoid race condition.
        // The proof might arrive before we get a chance to register after send.
        let packetTruncatedHash = packet.getTruncatedHash()
        let truncHashHex = packetTruncatedHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let msgHash = message.hash
        let msgHashHex = msgHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.info("Registering proof callback: packetHash=\(truncHashHex), msgHash=\(msgHashHex)")
        await transport.registerProofCallback(truncatedHash: packetTruncatedHash) { [weak self] in
            await self?.handleDeliveryProofReceived(messageHash: msgHash)
        }

        // Send via transport
        do {
            try await transport.send(packet: packet)
        } catch {
            // Remove proof callback on send failure
            await transport.removeProofCallback(truncatedHash: packetTruncatedHash)
            throw error
        }

        // Mark as sent
        message.state = .sent

        // Notify delegate
        notifyUpdate(message)
    }

    // MARK: - Direct Delivery

    /// Send message via Link (direct delivery).
    ///
    /// For direct delivery, establishes a link if needed and sends the full
    /// LXMF message over the link. Uses Resource for messages larger than
    /// LINK_PACKET_MAX_CONTENT.
    ///
    /// - Parameter message: Message to send (must be packed)
    /// - Throws: LXMFError if link establishment or send fails
    ///
    /// Reference: Python LXMRouter direct send (lines 2630-2680)
    public func sendDirect(_ message: inout LXMessage) async throws {
        let destHashHex = message.destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()

        let packedSize = message.packed?.count ?? 0
        let method = String(describing: message.method)
        directSendLogger.info("sendDirect called: dest=\(destHashHex), packed=\(packedSize) bytes, method=\(method)")

        guard let transport = self.transport else {
            directSendLogger.error("transport not available")
            throw LXMFError.transportNotAvailable
        }

        guard let packed = message.packed else {
            directSendLogger.error("message not packed")
            throw LXMFError.notPacked
        }

        // Get or establish link to destination
        directSendLogger.info("getting/establishing link to \(destHashHex)")
        let link: Link
        do {
            link = try await getOrEstablishLink(to: message.destinationHash, transport: transport)
            let linkId = await link.linkId
            let linkIdHex = linkId.prefix(8).map { String(format: "%02x", $0) }.joined()
            directSendLogger.info("link established: linkId=\(linkIdHex)")
        } catch {
            directSendLogger.error("link establishment failed: \(error)")
            throw error
        }

        // DO NOT proactively identify on the DIRECT link.
        //
        // Python's LXMRouter does NOT identify-as-router on the
        // outbound delivery link. The python identify call lives in
        // `LXMRouter.py:2530-2540` ("backchannel identification") and
        // happens *after* a message is delivered, using the SOURCE
        // delivery destination's identity (not the router identity).
        // The purpose: tell the recipient "you can reply to my
        // delivery destination over this same link." Swift's
        // `link.identify(identity: routerIdentity)` was identifying
        // with the wrong identity AND at the wrong moment, which
        // confused some receivers (echo bot in particular: smoke
        // direct_echo failed with state=SENT but no echo back —
        // tearing the link / mismatched identity context made the
        // bot's `on_delivery` handler not fire).
        //
        // The PROPAGATED path made the same fix earlier (LXMRouter
        // +Propagation.swift) referencing python LXMRouter.py:2682-2720.
        //
        // If a backchannel-identify becomes necessary for two-way
        // direct chat (which the echo bot exercises), it should be
        // a separate post-send step using the source delivery
        // identity, mirroring python LXMRouter.py:2530-2540.

        // Update message state
        message.state = .sending

        directSendLogger.info("packed size=\(packed.count), LINK_PACKET_MAX=\(LXMFConstants.LINK_PACKET_MAX_CONTENT)")

        // Branch tracks which path we took so the post-send state
        // transition can honor python's per-method semantics
        // (LXMessage.py:498-512): small-packet sets state=SENT
        // immediately because the packet has been transmitted (the
        // delivery proof later advances to DELIVERED); resource path
        // leaves state at SENDING because the resource is still being
        // transferred and `__mark_delivered` (LXMessage.py:556-566)
        // fires on `__resource_concluded` COMPLETE.
        let usedResourcePath: Bool
        // Send based on message size
        if packed.count <= LXMFConstants.LINK_PACKET_MAX_CONTENT {
            // Small enough for link DATA packet
            // IMPORTANT: Link packets must be encrypted using the link's derived key
            let encrypted: Data
            do {
                encrypted = try await link.encrypt(packed)
                directSendLogger.debug("Encrypted \(packed.count) bytes to \(encrypted.count) bytes for link")
            } catch {
                throw error
            }

            // Create link DATA packet
            // NOTE: Python RNS uses context=NONE (0x00) for regular link data
            // The LXMF message format is self-identifying, no special context needed
            let linkId = await link.linkId
            let linkIdHex = linkId.prefix(8).map { String(format: "%02x", $0) }.joined()

            // Get destination hash for path lookup (to determine if we need HEADER_2)
            let destHash = await link.destinationHash
            let destHashHex = destHash.prefix(8).map { String(format: "%02x", $0) }.joined()

            // Create HEADER_1 packet - transport.send() will convert to HEADER_2 if needed
            // by looking up the destination path
            let header = PacketHeader(
                headerType: .header1,
                hasContext: false,
                hasIFAC: false,
                transportType: .broadcast,
                destinationType: .link,
                packetType: .data,
                hopCount: 0
            )

            // Use destination hash for routing lookup, but linkId as actual destination
            let packet = Packet(
                header: header,
                destination: linkId,
                transportAddress: nil,
                context: 0x00,
                data: encrypted
            )

            try await sendLinkDataWithProofCallback(
                packet: packet,
                messageHash: message.hash,
                transport: transport
            )
            usedResourcePath = false
        } else {
            // Need Resource for large message
            directSendLogger.info("Message too large for link packet (\(packed.count) > \(LXMFConstants.LINK_PACKET_MAX_CONTENT)), using Resource transfer")

            // Set up outbound resource handler for delivery confirmation (double checkmark).
            // When RESOURCE_PRF is received, this handler maps resource hash → message hash
            // and calls handleDeliveryProofReceived() to update the DB and UI.
            let outboundHandler = LXMFOutboundResourceHandler(router: self)
            await link.setResourceCallbacks(outboundHandler)

            let resource = try await link.sendResource(data: packed, requestId: nil, isResponse: false)
            let numParts = await resource.numParts
            let resHash = await resource.hash
            let resHashHex = resHash?.prefix(8).map { String(format: "%02x", $0) }.joined() ?? "nil"
            directSendLogger.info("Resource created: hash=\(resHashHex), parts=\(numParts), advertisement sent")

            // Register resource hash → message hash for delivery confirmation
            if let resHash = resHash {
                let msgHash = message.hash
                let msgHashHex = msgHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                directSendLogger.info("Registered resource \(resHashHex) → message \(msgHashHex) for delivery confirmation")
                pendingResourceDeliveries[resHash] = msgHash
            }
            usedResourcePath = true
        }

        // Post-send state transition (python LXMessage.py:498-512).
        //
        // Small-packet path: the packet has been transmitted; state=
        // SENT now and `handleDeliveryProofReceived` advances to
        // DELIVERED when proof arrives. Same as PROPAGATED small-packet
        // (LXMRouter+Propagation.swift's `sendPropagated` post-
        // waitForPacketProof state flip).
        //
        // Resource path: state stays at .sending — the resource is
        // still being transferred. `handleResourceTransferComplete` →
        // `handleDeliveryProofReceived` advances to .delivered on
        // RESOURCE_PRF; `handleOutboundResourceFailed` re-enqueues
        // with state=.outbound on resource conclusion failure. The
        // matching DB persistence policy in `processOutbound`'s
        // DIRECT branch writes `.outbound` (NOT `.sending`) for the
        // resource-path case so a crash between this return and the
        // resource conclusion re-enqueues the message on next launch.
        if !usedResourcePath {
            message.state = .sent
            directSendLogger.info("Message marked sent for dest=\(destHashHex) (small-packet path)")
        } else {
            directSendLogger.info("Message left at .sending for dest=\(destHashHex) (resource path; awaiting RESOURCE_PRF)")
        }

        // Notify delegate
        notifyUpdate(message)
    }

    // MARK: - Link Management

    /// Get existing link or establish new one to destination.
    ///
    /// Link establishment flow:
    /// 1. Check for existing active link (return if available)
    /// 2. Look up PathEntry to get recipient's public keys
    /// 3. Create public-key-only Identity from path entry
    /// 4. Create LXMF delivery Destination from Identity
    /// 5. Initiate Link handshake (LINKREQUEST -> PROOF -> ACTIVE)
    /// 6. Store link for reuse
    ///
    /// - Parameters:
    ///   - destinationHash: Destination to link to
    ///   - transport: Transport for link packet delivery
    /// - Returns: Active link to destination
    /// - Throws: LXMFError if link establishment fails
    ///
    /// Reference: RNS Link.py, Python LXMF LXMRouter direct delivery
    private func getOrEstablishLink(to destinationHash: Data, transport: ReticulumTransport) async throws -> Link {
        let destHex = destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()

        // Check for existing delivery link
        if let link = deliveryLinks[destinationHash] {
            // Verify link is still active
            let state = await link.state
            if state == .active {
                return link
            }
            // Remove stale link
            deliveryLinks.removeValue(forKey: destinationHash)
        }

        // Resolve recipient identity. For self-send (own delivery
        // destinations), the path table has no entry — announces leave
        // the device, they don't loop back into the local table — so
        // check `deliveryDestinations` first. Mirrors python
        // `RNS.Identity.recall(hash)`. Same pattern as `sendPropagated`
        // and `sendOpportunistic`.
        let recipientIdentity: Identity
        if let localDest = deliveryDestinations[destinationHash]?.0,
           let localIdentity = localDest.identity {
            recipientIdentity = localIdentity
            routerLogger.debug("DIRECT self-link: resolving \(destHex) via local delivery destination")
        } else {
            guard let pathTable = self.pathTable else {
                throw LXMFError.transportNotAvailable
            }
            guard let pathEntry = await pathTable.lookup(destinationHash: destinationHash) else {
                throw LXMFError.destinationNotFound
            }
            do {
                recipientIdentity = try Identity(publicKeyBytes: pathEntry.publicKeys)
            } catch {
                throw LXMFError.invalidMessageFormat("Invalid recipient public keys: \(error.localizedDescription)")
            }
        }

        // Debug: print identity hash
        let identityHashHex = recipientIdentity.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.debug("Identity hash from public keys: \(identityHashHex)")

        // Create LXMF delivery Destination for the recipient
        // LXMF uses appName="lxmf", aspects=["delivery"]
        let destination = Destination(
            identity: recipientIdentity,
            appName: "lxmf",
            aspects: ["delivery"],
            type: .single,
            direction: .out
        )

        // Debug: print intermediate values
        let nameHashHex = destination.nameHash.map { String(format: "%02x", $0) }.joined()
        routerLogger.debug("Name hash (lxmf.delivery): \(nameHashHex.prefix(32))... (len=\(destination.nameHash.count))")

        // Verify destination hash matches what we expect
        // (ensures public keys map to the correct LXMF address)
        let computedHash = destination.hash
        let expectedHex = destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let computedHex = computedHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        guard computedHash == destinationHash else {
            // The public keys don't map to the expected LXMF destination
            // This can happen if the path entry is for a different destination type
            routerLogger.error("Hash mismatch: expected=\(expectedHex), computed=\(computedHex)")
            routerLogger.error("Public keys from path entry don't match LXMF delivery destination")
            throw LXMFError.invalidDestination
        }

        // Get local identity for link initiation (from LXMRouter's identity)
        let localIdentity = getLinkIdentity()

        // Use transport's initiateLink which properly registers the link
        // in pendingLinks so PROOF packets can be routed to it
        let link: Link
        do {
            link = try await transport.initiateLink(to: destination, identity: localIdentity)
            let linkId = await link.linkId
            let linkIdHex = linkId.prefix(8).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw error
        }

        // Also store in our delivery links for message routing
        deliveryLinks[destinationHash] = link

        // Wait for link to become active (with timeout)
        // Link will transition: pending -> handshake -> active
        // when PROOF packet is received
        do {
            try await waitForLinkActive(link, timeout: LXMFConstants.LINK_ESTABLISHMENT_TIMEOUT)
        } catch {
            // Clean up stale pending link from transport to prevent accumulation.
            // Without this, each failed attempt leaves a stale entry in pendingLinks,
            // causing link establishment delay (each retry creates a new link_id but
            // old ones are never cleaned up, and the receiver may respond to an old one).
            let linkId = await link.linkId
            let linkIdHex = linkId.prefix(8).map { String(format: "%02x", $0) }.joined()
            routerLogger.warning("Cleaning up stale pending link \(linkIdHex)")
            await transport.unregisterLink(linkId: linkId)
            deliveryLinks.removeValue(forKey: destinationHash)
            throw error
        }

        // Wire an unexpected-close callback on the now-ACTIVE link — the swift analog of
        // python's `process_outbound` CLOSED branch (LXMRouter.py:2628-2647). If the link
        // drops unexpectedly (peer gone / network drop) while a DIRECT small-packet is in
        // flight, react at once — pop the dead link + request a fresh path — instead of
        // waiting out the full DELIVERY_RETRY_WAIT gate. Wired only here, AFTER the link is
        // active (mirroring python's `activated_at != None` guard, LXMRouter.py:2629), so the
        // handshake-failure cleanup above never has a callback to reason about. Capture the
        // linkId for the handler's identity guard (so a stale OLD-link callback can't clobber
        // a message already re-sent over a NEWER link).
        let establishedLinkId = await link.linkId
        await link.setCloseCallback { [weak self] reason in
            await self?.handleLinkUnexpectedClose(
                destinationHash: destinationHash, linkId: establishedLinkId, reason: reason)
        }

        return link
    }

    /// Get local identity for link establishment.
    ///
    /// Returns the router's identity for signing link requests.
    private func getLinkIdentity() -> Identity {
        // Access the identity through the enclosing LXMRouter actor
        // This is set during router initialization
        return identity
    }

    /// Wait for link to become active with timeout.
    ///
    /// - Parameters:
    ///   - link: Link to wait for
    ///   - timeout: Maximum time to wait
    /// - Throws: LXMFError if timeout expires or link fails
    private func waitForLinkActive(_ link: Link, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let linkId = await link.linkId
        let linkIdHex = linkId.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.info("Waiting for link \(linkIdHex) to become active (timeout=\(timeout)s)")

        // Poll link state until active or timeout
        var lastState: LinkState = .pending
        var pollCount = 0
        while Date() < deadline {
            let state = await link.state
            pollCount += 1
            if pollCount % 10 == 0 {
                routerLogger.debug("Poll #\(pollCount): link \(linkIdHex) state=\(String(describing: state))")
            }
            if state != lastState {
                routerLogger.info("Link \(linkIdHex) state changed: \(String(describing: lastState)) -> \(String(describing: state))")
                lastState = state
            }
            switch state {
            case .active:
                routerLogger.info("Link \(linkIdHex) is now active")
                // Wait a bit for remote to set up its packet callback
                // This is needed because Python's LXMF sets up packet_callback
                // in link_established callback, which might race with our send
                try? await Task.sleep(for: .milliseconds(100))
                routerLogger.debug("Link \(linkIdHex) ready to send")
                return
            case .closed:
                routerLogger.warning("Link \(linkIdHex) closed unexpectedly")
                throw LXMFError.linkFailed("Link closed unexpectedly")
            default:
                // Still pending or handshaking, wait and retry
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        // Timeout - link didn't become active
        routerLogger.error("Link \(linkIdHex) establishment timed out (state=\(String(describing: lastState)), polls=\(pollCount))")
        throw LXMFError.linkFailed("Link establishment timed out after \(timeout) seconds")
    }

    // MARK: - Proof-callback registration helper

    /// Register a delivery-proof callback on `transport` keyed by the
    /// truncated hash of `packet`, then send the encrypted link DATA.
    /// On send failure, remove the callback and rethrow so a stale
    /// entry doesn't sit in `pendingProofCallbacks` forever.
    ///
    /// Mirrors python's
    /// `lxm_packet.send().set_delivery_callback(__mark_delivered)` for
    /// the DIRECT/PACKET branch in `LXMessage.send()`. Without this,
    /// small DIRECT messages stop at `.sent` on the swift sender even
    /// when the receiver has acked, because the proof comes back over
    /// the link as a `.proof` packet whose truncated hash matches
    /// the *outbound* packet — that's what the callback is keyed on.
    ///
    /// Extracted from `sendDirect` so the registration / error-cleanup
    /// path is unit-testable in isolation: a real `sendDirect` test
    /// would have to drive an active link with derived keys to reach
    /// this block, but the logic itself is independent of link state.
    ///
    /// - Parameters:
    ///   - packet: encrypted link DATA packet to send. The packet is
    ///     addressed to the linkId; `transport.sendLinkData` routes
    ///     it to the link's pinned `attached_interface` per python
    ///     `Transport.outbound` (RNS/Transport.py:1122-1130).
    ///   - messageHash: hash of the LXMessage; the proof callback
    ///     calls `handleDeliveryProofReceived(messageHash:)` with
    ///     this so the right outbound message advances to `.delivered`.
    ///   - transport: transport actor to register the callback on
    ///     and send through.
    internal func sendLinkDataWithProofCallback(
        packet: Packet,
        messageHash: Data,
        transport: ReticulumTransport
    ) async throws {
        let packetTruncatedHash = packet.getTruncatedHash()
        await transport.registerProofCallback(truncatedHash: packetTruncatedHash) { [weak self] in
            await self?.handleDeliveryProofReceived(messageHash: messageHash)
        }
        do {
            try await transport.sendLinkData(packet: packet)
        } catch {
            await transport.removeProofCallback(truncatedHash: packetTruncatedHash)
            throw error
        }
    }

    /// Tear down the cached delivery link to `destinationHash` (sending a LINKCLOSE) and drop
    /// it from `deliveryLinks` + the transport. The DIRECT analog of python
    /// `__link_packet_timed_out` → `packet_receipt.destination.teardown()` (LXMessage.py:615)
    /// and `process_outbound`'s link-CLOSED branch popping `direct_links` (LXMRouter.py:2638-2641):
    /// when a small-packet DIRECT message's proof-wait window elapses with no proof, `processOutbound`
    /// calls this so the message re-establishes a FRESH link on its re-send rather than reusing a
    /// possibly-dead one. No-op if no link is cached. Reuses the same teardown primitives as the
    /// stale-link cleanup in `getOrEstablishLink`. No reticulum-swift change required.
    internal func closeAndRemoveDeliveryLink(_ destinationHash: Data) async {
        guard let link = deliveryLinks.removeValue(forKey: destinationHash) else { return }
        let linkId = await link.linkId
        // Clear the unexpected-close callback BEFORE our DELIBERATE teardown so our own
        // close doesn't re-enter `handleLinkUnexpectedClose`. `reason == .timeout` is
        // otherwise indistinguishable from a watchdog-driven close, so callback-presence —
        // not the reason — is the our-own-close vs unexpected-close discriminator. A no-op
        // if the link already fired (it clears its own callback on fire).
        await link.setCloseCallback(nil)
        await link.close(reason: .timeout)
        await transport?.unregisterLink(linkId: linkId)
    }
}


// MARK: - Delivery Errors

extension LXMFError {
    /// Transport not available for sending
    public static let transportNotAvailable = LXMFError.linkFailed("Transport not available")

    /// Destination not found in path table
    public static let destinationNotFound = LXMFError.noPath
}
