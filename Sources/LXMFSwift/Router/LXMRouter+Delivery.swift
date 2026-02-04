//
//  LXMRouter+Delivery.swift
//  LXMFSwift
//
//  LXMF message delivery methods: opportunistic and direct.
//  Integrates with ReticuLumTransport for packet sending and Link for direct delivery.
//
//  Reference: LXMF/LXMRouter.py lines 2496-2700
//

import Foundation
import CryptoKit
import ReticulumSwift

/// Helper to append debug messages to file (Delivery extension)
private func appendDeliveryDebug(_ message: String) {
    let line = "[\(Date())] \(message)\n"
    let path = "/tmp/columba_router_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        handle.closeFile()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
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
        appendDeliveryDebug("[OPP_SEND] Starting sendOpportunistic")

        guard let transport = self.transport else {
            appendDeliveryDebug("[OPP_SEND] ERROR: transport not available")
            throw LXMFError.transportNotAvailable
        }

        guard let pathTable = self.pathTable else {
            appendDeliveryDebug("[OPP_SEND] ERROR: pathTable not available")
            throw LXMFError.transportNotAvailable
        }

        guard let packed = message.packed else {
            appendDeliveryDebug("[OPP_SEND] ERROR: message not packed (packed=nil)")
            throw LXMFError.notPacked
        }
        appendDeliveryDebug("[OPP_SEND] Message packed, \(packed.count) bytes")

        // Look up path entry for destination to get their public key
        let destHex = message.destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        guard let pathEntry = await pathTable.lookup(destinationHash: message.destinationHash) else {
            appendDeliveryDebug("[OPP_SEND] ERROR: no path entry for \(destHex)")
            throw LXMFError.destinationNotFound
        }
        appendDeliveryDebug("[OPP_SEND] Found path entry for \(destHex), hops=\(pathEntry.hopCount)")

        // Get recipient's encryption public key (use ratchet if available, otherwise base key)
        // When a destination announces with a ratchet, we MUST use the ratchet key for
        // forward secrecy - the recipient will decrypt using their current ratchet private key.
        let effectiveKey = pathEntry.effectiveEncryptionKey
        let hasRatchet = pathEntry.ratchet != nil && pathEntry.ratchet!.count == 32
        let keyHex = effectiveKey.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("[LXMF_SEND] Using encryption key[0:8]=\(keyHex), hasRatchet=\(hasRatchet)")

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
        let identityHash = Hashing.truncatedHash(pathEntry.publicKeys)
        let identityHashHex = identityHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("[LXMF_SEND] Using identityHash[0:8]=\(identityHashHex) as HKDF salt")

        // For opportunistic: destination is in packet header, not data
        // Packed format: dest_hash (16) + source_hash (16) + signature (64) + msgpack
        // We skip first 16 bytes (dest_hash) since it's in packet header
        let plaintextData = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))

        // Encrypt data to recipient's public key using SINGLE destination encryption
        // Output format: [ephemeral_pub 32B][IV 16B][ciphertext][HMAC 32B]
        // NOTE: The HKDF salt is the IDENTITY hash (from public keys), NOT the destination hash!
        appendDeliveryDebug("[OPP_SEND] Encrypting \(plaintextData.count) bytes")
        let encryptedData: Data
        do {
            encryptedData = try Identity.encrypt(
                plaintextData,
                to: recipientEncryptionPubKey,
                identityHash: identityHash  // Use identity hash as HKDF salt per Python RNS
            )
            appendDeliveryDebug("[OPP_SEND] Encrypted to \(encryptedData.count) bytes")
        } catch {
            appendDeliveryDebug("[OPP_SEND] ERROR: encryption failed: \(error)")
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

        // Send via transport
        appendDeliveryDebug("[OPP_SEND] Sending packet via transport...")
        do {
            try await transport.send(packet: packet)
            appendDeliveryDebug("[OPP_SEND] Packet sent successfully!")
        } catch {
            appendDeliveryDebug("[OPP_SEND] ERROR: transport.send failed: \(error)")
            throw error
        }

        // Mark as sent
        message.state = .sent

        // Notify delegate
        notifyUpdate(message)
        appendDeliveryDebug("[OPP_SEND] Message marked as sent")
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
        appendDeliveryDebug("[DELIVERY] sendDirect called for \(destHashHex)")

        guard let transport = self.transport else {
            appendDeliveryDebug("[DELIVERY] ERROR: transport is nil")
            print("[LXMF_DIRECT] Error: transport not available")
            throw LXMFError.transportNotAvailable
        }
        appendDeliveryDebug("[DELIVERY] transport is available")

        guard let packed = message.packed else {
            appendDeliveryDebug("[DELIVERY] ERROR: message not packed")
            print("[LXMF_DIRECT] Error: message not packed")
            throw LXMFError.notPacked
        }
        appendDeliveryDebug("[DELIVERY] message packed, size=\(packed.count)")

        // Get or establish link to destination
        appendDeliveryDebug("[DELIVERY] Getting/establishing link to \(destHashHex)")
        print("[LXMF_DIRECT] sendDirect: getting/establishing link to \(destHashHex)")
        let link: Link
        do {
            link = try await getOrEstablishLink(to: message.destinationHash, transport: transport)
            print("[LXMF_DIRECT] sendDirect: link established to \(destHashHex)")
            appendDeliveryDebug("[DIRECT] Link established to \(destHashHex)")
        } catch {
            print("[LXMF_DIRECT] sendDirect: link establishment failed: \(error)")
            appendDeliveryDebug("[DIRECT] Link establishment FAILED: \(error)")
            throw error
        }

        // Identify ourselves to the remote peer so they can respond
        // This sends our public keys over the link, enabling bidirectional LXMF
        appendDeliveryDebug("[DIRECT] Calling link.identify()")
        do {
            try await link.identify(identity: identity)
            print("[LXMF_DIRECT] sendDirect: identified to remote peer")
            appendDeliveryDebug("[DIRECT] identify() succeeded")
        } catch {
            // Identification failure is not fatal - message can still be delivered
            // but the remote may not be able to respond
            print("[LXMF_DIRECT] sendDirect: identify failed (non-fatal): \(error)")
            appendDeliveryDebug("[DIRECT] identify() FAILED (non-fatal): \(error)")
        }

        // Update message state
        message.state = .sending
        appendDeliveryDebug("[DIRECT] Message state -> sending, packed.count=\(packed.count)")

        // Send based on message size
        if packed.count <= LXMFConstants.LINK_PACKET_MAX_CONTENT {
            // Small enough for link DATA packet
            // IMPORTANT: Link packets must be encrypted using the link's derived key
            appendDeliveryDebug("[DIRECT] Encrypting \(packed.count) bytes for link")
            let encrypted: Data
            do {
                encrypted = try await link.encrypt(packed)
                print("[LXMF_DIRECT] Encrypted \(packed.count) bytes to \(encrypted.count) bytes for link")
                appendDeliveryDebug("[DIRECT] Encrypted to \(encrypted.count) bytes")
            } catch {
                appendDeliveryDebug("[DIRECT] ENCRYPT FAILED: \(error)")
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
            appendDeliveryDebug("[DIRECT] Creating DATA packet: linkId=\(linkIdHex), destHash=\(destHashHex)")

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

            appendDeliveryDebug("[DIRECT] Sending DATA packet via transport (destHash=\(destHashHex) for routing)")
            try await transport.sendLinkData(packet: packet, destinationHash: destHash)
            appendDeliveryDebug("[DIRECT] DATA packet sent successfully")
        } else {
            // Need Resource for large message
            // Link.sendResource handles chunking and transfer
            appendDeliveryDebug("[DIRECT] Message too large (\(packed.count) bytes), using Resource")
            try await link.sendResource(data: packed, requestId: nil, isResponse: false)
            appendDeliveryDebug("[DIRECT] Resource transfer complete")
        }

        // Mark as sent
        message.state = .sent
        appendDeliveryDebug("[DIRECT] Message state -> sent")

        // Notify delegate
        notifyUpdate(message)
        appendDeliveryDebug("[DIRECT] Delegate notified, sendDirect complete")
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
    private func getOrEstablishLink(to destinationHash: Data, transport: ReticuLumTransport) async throws -> Link {
        let destHex = destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        appendDeliveryDebug("[LINK] getOrEstablishLink to \(destHex)")

        // Check for existing delivery link
        if let link = deliveryLinks[destinationHash] {
            // Verify link is still active
            let state = await link.state
            appendDeliveryDebug("[LINK] Found existing link, state=\(state)")
            if state == .active {
                return link
            }
            // Remove stale link
            appendDeliveryDebug("[LINK] Removing stale link")
            deliveryLinks.removeValue(forKey: destinationHash)
        }

        // Look up path entry to get recipient's public keys
        guard let pathTable = self.pathTable else {
            appendDeliveryDebug("[LINK] ERROR: pathTable is nil")
            throw LXMFError.transportNotAvailable
        }

        guard let pathEntry = await pathTable.lookup(destinationHash: destinationHash) else {
            appendDeliveryDebug("[LINK] ERROR: path entry not found for \(destHex)")
            throw LXMFError.destinationNotFound
        }
        appendDeliveryDebug("[LINK] Found path entry, publicKeys len=\(pathEntry.publicKeys.count)")

        // Create public-key-only Identity from path entry's public keys
        let recipientIdentity: Identity
        do {
            recipientIdentity = try Identity(publicKeyBytes: pathEntry.publicKeys)
        } catch {
            throw LXMFError.invalidMessageFormat("Invalid recipient public keys: \(error.localizedDescription)")
        }

        // Debug: print identity hash
        let identityHashHex = recipientIdentity.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("[LXMF_LINK] Identity hash from public keys: \(identityHashHex)")

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
        print("[LXMF_LINK] Name hash (lxmf.delivery): \(nameHashHex.prefix(32))... (len=\(destination.nameHash.count))")

        // Verify destination hash matches what we expect
        // (ensures public keys map to the correct LXMF address)
        let computedHash = destination.hash
        let expectedHex = destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let computedHex = computedHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        guard computedHash == destinationHash else {
            // The public keys don't map to the expected LXMF destination
            // This can happen if the path entry is for a different destination type
            print("[LXMF_LINK] Hash mismatch: expected=\(expectedHex), computed=\(computedHex)")
            print("[LXMF_LINK] Public keys from path entry don't match LXMF delivery destination")
            throw LXMFError.invalidDestination
        }

        // Get local identity for link initiation (from LXMRouter's identity)
        let localIdentity = getLinkIdentity()
        appendDeliveryDebug("[LINK] Got local identity, initiating link")

        // Use transport's initiateLink which properly registers the link
        // in pendingLinks so PROOF packets can be routed to it
        let link: Link
        do {
            link = try await transport.initiateLink(to: destination, identity: localIdentity)
            let linkId = await link.linkId
            let linkIdHex = linkId.prefix(8).map { String(format: "%02x", $0) }.joined()
            appendDeliveryDebug("[LINK] Link initiated, linkId=\(linkIdHex)")
        } catch {
            appendDeliveryDebug("[LINK] ERROR: initiateLink failed: \(error)")
            throw error
        }

        // Also store in our delivery links for message routing
        deliveryLinks[destinationHash] = link

        // Wait for link to become active (with timeout)
        // Link will transition: pending -> handshake -> active
        // when PROOF packet is received
        appendDeliveryDebug("[LINK] Waiting for link to become active")
        do {
            try await waitForLinkActive(link, timeout: LXMFConstants.LINK_ESTABLISHMENT_TIMEOUT)
            appendDeliveryDebug("[LINK] Link is now active")
        } catch {
            appendDeliveryDebug("[LINK] ERROR: waitForLinkActive failed: \(error)")
            throw error
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
        print("[LXMF_LINK] Waiting for link \(linkIdHex) to become active (timeout=\(timeout)s)")

        // Poll link state until active or timeout
        var lastState: LinkState = .pending
        var pollCount = 0
        while Date() < deadline {
            let state = await link.state
            pollCount += 1
            if pollCount % 10 == 0 {
                print("[LXMF_LINK] Poll #\(pollCount): link \(linkIdHex) state=\(state)")
            }
            if state != lastState {
                print("[LXMF_LINK] Link \(linkIdHex) state changed: \(lastState) -> \(state)")
                lastState = state
            }
            switch state {
            case .active:
                print("[LXMF_LINK] Link \(linkIdHex) is now active!")
                // Wait a bit for remote to set up its packet callback
                // This is needed because Python's LXMF sets up packet_callback
                // in link_established callback, which might race with our send
                try? await Task.sleep(for: .milliseconds(100))
                print("[LXMF_LINK] Link \(linkIdHex) ready to send")
                return
            case .closed:
                print("[LXMF_LINK] Link \(linkIdHex) closed unexpectedly")
                throw LXMFError.linkFailed("Link closed unexpectedly")
            default:
                // Still pending or handshaking, wait and retry
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        // Timeout - link didn't become active
        print("[LXMF_LINK] Link \(linkIdHex) establishment timed out (state=\(lastState), polls=\(pollCount))")
        throw LXMFError.linkFailed("Link establishment timed out after \(timeout) seconds")
    }
}


// MARK: - Delivery Errors

extension LXMFError {
    /// Transport not available for sending
    public static let transportNotAvailable = LXMFError.linkFailed("Transport not available")

    /// Destination not found in path table
    public static let destinationNotFound = LXMFError.noPath
}
