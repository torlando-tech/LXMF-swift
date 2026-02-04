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
    /// Reconstructs the full LXMF wire format and routes to lxmfDelivery.
    ///
    /// - Parameters:
    ///   - data: Packet data
    ///   - packet: Parsed packet header and metadata
    public func deliveryPacket(_ data: Data, _ packet: Packet) async {
        let destHex = packet.destination.prefix(8).map { String(format: "%02x", $0) }.joined()
        print("[LXMF_INBOUND] deliveryPacket called: destType=\(packet.header.destinationType), destHash=\(destHex), dataLen=\(data.count)")

        // Reconstruct full LXMF data based on packet type
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

        // Route to delivery handler
        print("[LXMF_INBOUND] Calling lxmfDelivery() with \(lxmfData.count) bytes")
        let accepted = await lxmfDelivery(lxmfData)
        print("[LXMF_INBOUND] lxmfDelivery() returned accepted=\(accepted)")
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
