// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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
import os.log

private let routerLogger = Logger(subsystem: "net.reticulum.lxmf", category: "LXMRouter")

// MARK: - LXMF Resource Handler

/// Resource callback handler for LXMF direct delivery over links.
///
/// When a resource transfer completes on an LXMF delivery link, the
/// assembled data is delivered to the router's lxmfDelivery handler.
///
/// Reference: Python LXMF/LXMRouter.py delivery_resource_concluded()
final class LXMFResourceHandler: ResourceCallbacks, @unchecked Sendable {
    private let router: LXMRouter

    init(router: LXMRouter) {
        self.router = router
    }

    func resourceConcluded(_ resource: Resource) async {
        // Get assembled data from the completed resource
        guard let data = await resource.assembledData else {
            routerLogger.warning("Resource concluded but no assembled data available")
            return
        }

        routerLogger.info("Resource transfer complete, delivering \(data.count) bytes to LXMF")
        // Resource transfers always travel over an established link, so this is
        // unambiguously a DIRECT delivery. Python: delivery_resource_concluded()
        // calls lxmf_delivery(..., method=LXMessage.DIRECT). LXMRouter.py:1878.
        let accepted = await router.lxmfDelivery(data, method: .direct)
        routerLogger.info("lxmfDelivery returned accepted=\(accepted)")
    }
}

extension LXMRouter {

    // MARK: - Delivery Destinations

    /// Register a destination to receive LXMF messages.
    ///
    /// When a packet is received for this destination, it will be routed to
    /// the router's lxmfDelivery handler for unpacking and processing.
    ///
    /// Also registers a link callback so that inbound links to this destination
    /// are configured for resource transfer (needed for large messages).
    ///
    /// Reference: Python LXMF/LXMRouter.py delivery_link_established()
    ///
    /// - Parameters:
    ///   - destination: Destination to register for LXMF delivery
    ///   - stampCost: Optional stamp cost to enforce (nil = no stamping required)
    public func registerDeliveryDestination(_ destination: Destination, stampCost: Int? = nil) async throws {
        let destHex = destination.hash.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.info("registerDeliveryDestination: destHash=\(destHex)")

        // Store destination and optional stamp cost
        deliveryDestinations[destination.hash] = (destination, stampCost)
        routerLogger.debug("Stored in deliveryDestinations, count=\(self.deliveryDestinations.count)")

        // Register destination with transport if available
        guard let transport = transport else {
            routerLogger.error("Transport not available for delivery registration")
            throw LXMFError.transportNotAvailable
        }

        await transport.registerDestination(destination)
        routerLogger.info("Registered destination with transport")

        // Register callback to receive packets for this destination
        // IMPORTANT: Use registerAsync to ensure callback is registered before returning
        let callbackManager = await transport.getCallbackManager()
        routerLogger.debug("Got callbackManager, registering callback for \(destHex)")
        await callbackManager.registerAsync(destinationHash: destination.hash) { [weak self] (data: Data, packet: Packet) in
            routerLogger.info("Delivery callback invoked for dest=\(destHex), dataLen=\(data.count)")
            guard let self = self else {
                routerLogger.error("Router deallocated in delivery callback")
                return
            }
            Task {
                await self.deliveryPacket(data, packet)
            }
        }
        routerLogger.debug("Callback registered successfully")

        // Register link callback for resource-based direct delivery
        // When a remote peer establishes a link to our delivery destination,
        // we need to accept resources (large LXMF messages sent via Resource transfer).
        // Reference: Python LXMF/LXMRouter.py delivery_link_established() lines 1847-1852
        let resourceHandler = LXMFResourceHandler(router: self)
        await transport.registerDestinationLinkCallback(for: destination.hash) { [resourceHandler] (link: Link) async in
            routerLogger.info("Inbound link established, configuring resource handling")
            await link.setResourceStrategy(.acceptAll)
            await link.setResourceCallbacks(resourceHandler)
            routerLogger.debug("Resource strategy=acceptAll, callbacks set")
        }
        routerLogger.debug("Link callback registered for resource handling")
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
        routerLogger.info("deliveryPacket: destType=\(String(describing: packet.header.destinationType)), destHash=\(destHex), dataLen=\(data.count)")

        // STEP 1: Send delivery proof IMMEDIATELY (before unpacking)
        // Reference: Python Packet.prove() -> Identity.prove()
        // The proof proves we received the packet by signing its hash
        await sendDeliveryProof(for: packet)

        // STEP 2: Reconstruct full LXMF data based on packet type and classify the
        // delivery method. Mirrors Python LXMRouter.delivery_packet() lines 1820-1828:
        //   if packet.destination_type != RNS.Destination.LINK: method = OPPORTUNISTIC
        //   else:                                                method = DIRECT
        var lxmfData = Data()
        let method: LXDeliveryMethod

        if packet.header.destinationType != .link {
            // Opportunistic: data is missing destination hash prefix
            // Prepend destination hash from packet
            lxmfData.append(packet.destination)
            lxmfData.append(data)
            method = .opportunistic
            routerLogger.debug("Opportunistic: prepended destHash, lxmfData len=\(lxmfData.count)")
        } else {
            // Direct over link: data is complete LXMF message (small, fits in a single
            // link DATA packet — large messages take the resource path which is handled
            // by LXMFResourceHandler.resourceConcluded above).
            lxmfData = data
            method = .direct
            routerLogger.debug("Link delivery: using data as-is, lxmfData len=\(lxmfData.count)")
        }

        // STEP 3: Route to delivery handler for unpacking and validation
        let stats = PhysicalStats(receivingInterface: packet.receivingInterface)
        routerLogger.info("Calling lxmfDelivery() with \(lxmfData.count) bytes, method=\(String(describing: method)), interface=\(packet.receivingInterface ?? "nil")")
        let accepted = await lxmfDelivery(lxmfData, physicalStats: stats, method: method)
        routerLogger.info("lxmfDelivery() returned accepted=\(accepted)")
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
            routerLogger.error("Cannot send proof: transport not available")
            return
        }

        // Link-delivered packets (DIRECT) need a link-context proof
        // (explicit format: 32-byte hash + 64-byte signature, addressed
        // to the link, signed with the link's signing key). The
        // standalone SINGLE-implicit proof we emit for OPPORTUNISTIC
        // would be silently rejected by python's
        // PacketReceipt.validate_link_proof (which requires explicit
        // format and validates against the link's peer_sig_pub), so
        // DIRECT outbound state would never advance to `delivered`
        // even though the message arrived.
        if packet.header.destinationType == .link,
           let link = await transport.getLink(linkId: packet.destination) {
            do {
                try await link.provePacket(packet)
                let hashHex = packet.getFullHash().prefix(8).map { String(format: "%02x", $0) }.joined()
                routerLogger.info("Link delivery proof sent for packet \(hashHex)")
            } catch {
                routerLogger.error("Failed to send link delivery proof: \(error)")
            }
            return
        }

        // Compute packet hash (used as proof destination and signature input)
        let packetHash = packet.getFullHash()
        let proofDestination = packet.getTruncatedHash()

        let hashHex = packetHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let destHex = proofDestination.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.info("Generating proof: packetHash=\(hashHex), proofDest=\(destHex)")

        // Sign the packet hash with our identity
        let signature: Data
        do {
            signature = try identity.sign(packetHash)
            let sigHex = signature.prefix(8).map { String(format: "%02x", $0) }.joined()
            routerLogger.debug("Signed with identity, signature[0:8]=\(sigHex)")
        } catch {
            routerLogger.error("Failed to sign packet hash: \(error)")
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
            routerLogger.info("Delivery proof sent successfully to \(destHex)")
        } catch {
            routerLogger.error("Failed to send delivery proof: \(error)")
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
