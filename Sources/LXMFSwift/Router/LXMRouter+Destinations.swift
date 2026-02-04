//
//  LXMRouter+Destinations.swift
//  LXMFSwift
//
//  LXMF destination registration and delivery packet handling.
//  Registers destinations with transport to receive inbound LXMF messages.
//
//  Reference: LXMF/LXMRouter.py lines 1714-1799 (lxmf_delivery)
//

import Foundation
import ReticulumSwift

extension LXMRouter {

    // MARK: - Delivery Destinations

    /// Register a destination to receive LXMF messages.
    ///
    /// When a packet is received for this destination, it will be routed to
    /// the router's lxmfDelivery handler for unpacking and processing.
    ///
    /// - Parameters:
    ///   - destination: Destination to register for LXMF delivery
    ///   - stampCost: Optional stamp cost to enforce (nil = no stamping required)
    public func registerDeliveryDestination(_ destination: Destination, stampCost: Int? = nil) async throws {
        let destHex = destination.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("[LXMF_INBOUND] registerDeliveryDestination: destHash=\(destHex)")

        // Store destination and optional stamp cost
        deliveryDestinations[destination.hash] = (destination, stampCost)
        print("[LXMF_INBOUND] Stored in deliveryDestinations, count=\(deliveryDestinations.count)")

        // Register destination with transport if available
        guard let transport = transport else {
            print("[LXMF_INBOUND] ERROR: transport not available!")
            throw LXMFError.transportNotAvailable
        }

        await transport.registerDestination(destination)
        print("[LXMF_INBOUND] Registered destination with transport")

        // Register callback to receive packets for this destination
        // IMPORTANT: Use registerAsync to ensure callback is registered before returning
        let callbackManager = await transport.getCallbackManager()
        print("[LXMF_INBOUND] Got callbackManager, registering callback for \(destHex)")
        await callbackManager.registerAsync(destinationHash: destination.hash) { [weak self] (data: Data, packet: Packet) in
            print("[LXMF_INBOUND] *** CALLBACK INVOKED *** for dest=\(destHex), dataLen=\(data.count)")
            guard let self = self else {
                print("[LXMF_INBOUND] ERROR: self is nil in callback!")
                return
            }
            Task {
                await self.deliveryPacket(data, packet)
            }
        }
        print("[LXMF_INBOUND] Callback registered successfully")
    }

    /// Handle delivery packet received for LXMF destination.
    ///
    /// This is called when a packet arrives for a registered LXMF destination.
    /// IMPORTANT: Sends delivery proof FIRST, then unpacks and validates the message.
    ///
    /// Reference: Python LXMF/LXMRouter.py delivery_packet() lines 1817-1818
    /// The proof is sent immediately upon packet reception, before message validation.
    ///
    /// - Parameters:
    ///   - data: Packet data
    ///   - packet: Parsed packet header and metadata
    public func deliveryPacket(_ data: Data, _ packet: Packet) async {
        let destHex = packet.destination.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("[LXMF_INBOUND] deliveryPacket called: destType=\(packet.header.destinationType), destHash=\(destHex), dataLen=\(data.count)")

        // STEP 1: Send delivery proof IMMEDIATELY (before unpacking)
        // Reference: Python Packet.prove() -> Identity.prove()
        // The proof proves we received the packet by signing its hash
        await sendDeliveryProof(for: packet)

        // STEP 2: Reconstruct full LXMF data based on packet type
        var lxmfData = Data()

        if packet.header.destinationType != .link {
            // Opportunistic: data is missing destination hash prefix
            // Prepend destination hash from packet
            lxmfData.append(packet.destination)
            lxmfData.append(data)
            print("[LXMF_INBOUND] Opportunistic: prepended destHash, lxmfData len=\(lxmfData.count)")
        } else {
            // Direct over link: data is complete LXMF message
            lxmfData = data
            print("[LXMF_INBOUND] Link delivery: using data as-is, lxmfData len=\(lxmfData.count)")
        }

        // STEP 3: Route to delivery handler for unpacking and validation
        print("[LXMF_INBOUND] Calling lxmfDelivery() with \(lxmfData.count) bytes")
        let accepted = await lxmfDelivery(lxmfData)
        print("[LXMF_INBOUND] lxmfDelivery() returned accepted=\(accepted)")
    }

    /// Send a delivery proof for a received packet.
    ///
    /// The proof is a PROOF packet containing:
    /// - Destination: Truncated hash of received packet (16 bytes)
    /// - Data: Ed25519 signature of the full packet hash (64 bytes)
    ///
    /// This proves to the sender that we received their packet.
    /// The proof is routed back using the packet hash as destination,
    /// which transport nodes can match to pending deliveries.
    ///
    /// Reference: Python RNS Identity.prove() lines 807-818
    ///
    /// - Parameter packet: The received packet to prove
    private func sendDeliveryProof(for packet: Packet) async {
        guard let transport = transport else {
            print("[LXMF_PROOF] Cannot send proof: transport not available")
            return
        }

        // Compute packet hash (used as proof destination and signature input)
        let packetHash = packet.getFullHash()
        let proofDestination = packet.getTruncatedHash()

        let hashHex = packetHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let destHex = proofDestination.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("[LXMF_PROOF] Generating proof: packetHash=\(hashHex), proofDest=\(destHex)")

        // Sign the packet hash with our identity
        let signature: Data
        do {
            signature = try identity.sign(packetHash)
            let sigHex = signature.prefix(8).map { String(format: "%02x", $0) }.joined()
            print("[LXMF_PROOF] Signed with identity, signature[0:8]=\(sigHex)")
        } catch {
            print("[LXMF_PROOF] Failed to sign packet hash: \(error)")
            return
        }

        // Create PROOF packet
        // Reference: Python Packet.py PROOF type = 0x03
        // Header: HEADER_1, destinationType=SINGLE, packetType=PROOF
        let proofHeader = PacketHeader(
            headerType: .header1,
            hasContext: false,
            hasIFAC: false,
            transportType: .broadcast,
            destinationType: .single,
            packetType: .proof,
            hopCount: 0
        )

        let proofPacket = Packet(
            header: proofHeader,
            destination: proofDestination,
            transportAddress: nil,
            context: 0x00,  // NONE context
            data: signature  // 64-byte Ed25519 signature (implicit proof mode)
        )

        // Send proof via transport
        do {
            try await transport.send(packet: proofPacket)
            print("[LXMF_PROOF] Delivery proof sent successfully to \(destHex)")
        } catch {
            print("[LXMF_PROOF] Failed to send delivery proof: \(error)")
        }
    }

    // MARK: - Announce Handling

    /// Handle received announce to cache stamp cost.
    ///
    /// When an announce is received, extract any LXMF stamp cost from the
    /// app_data field and cache it for future outbound messages.
    ///
    /// - Parameter announce: Parsed announce packet
    public func handleAnnounce(_ announce: ParsedAnnounce) {
        // Cache stamp cost from announce app_data if present
        if let appData = announce.appData,
           let cost = parseStampCostFromAppData(appData) {
            outboundStampCosts[announce.destinationHash] = (Date(), cost)
        }
    }

    /// Parse stamp cost from announce app_data.
    ///
    /// LXMF stamp costs are stored in app_data as msgpack: {"lxmf_stamp": cost}
    ///
    /// - Parameter appData: App data from announce
    /// - Returns: Stamp cost if present, nil otherwise
    private func parseStampCostFromAppData(_ appData: Data) -> Int? {
        // TODO: Implement msgpack parsing for stamp cost
        // For now, return nil (stamping deferred to future plan)
        return nil
    }
}
