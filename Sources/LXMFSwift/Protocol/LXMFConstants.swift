// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMFConstants.swift
//  LXMFSwift
//
//  LXMF protocol constants matching Python LXMF exactly.
//
//  Reference: LXMF/LXMessage.py lines 39-94
//

import Foundation

/// LXMF protocol constants.
///
/// These values must match the Python LXMF implementation exactly for
/// byte-perfect interoperability.
///
/// Reference: LXMF/LXMessage.py lines 39-94
public enum LXMFConstants {

    // MARK: - Hash and Signature Lengths

    /// Destination hash length in bytes (truncated hash)
    /// Python: DESTINATION_LENGTH = RNS.Identity.TRUNCATED_HASHLENGTH//8 = 16
    public static let DESTINATION_LENGTH = 16

    /// Ed25519 signature length in bytes
    /// Python: SIGNATURE_LENGTH = RNS.Identity.SIGLENGTH//8 = 64
    public static let SIGNATURE_LENGTH = 64

    /// Ticket hash length in bytes (for propagation nodes)
    /// Python: TICKET_LENGTH = RNS.Identity.TRUNCATED_HASHLENGTH//8 = 16
    public static let TICKET_LENGTH = 16

    // MARK: - Ticket Timing (for propagation)

    /// Default ticket expiry: 3 weeks in seconds
    public static let TICKET_EXPIRY = 21 * 24 * 60 * 60

    /// Grace period for timekeeping inaccuracies: 5 days
    public static let TICKET_GRACE = 5 * 24 * 60 * 60

    /// Auto-renew tickets when less than 14 days to expiry
    public static let TICKET_RENEW = 14 * 24 * 60 * 60

    /// Ticket refresh check interval: 1 day
    public static let TICKET_INTERVAL = 1 * 24 * 60 * 60

    /// Proof-of-work cost for ticket generation
    public static let COST_TICKET = 0x100

    // MARK: - LXMF Overhead Calculation

    /// Timestamp field size in bytes (Double = 8 bytes)
    /// Python: TIMESTAMP_SIZE = 8
    public static let TIMESTAMP_SIZE = 8

    /// MessagePack structure overhead in bytes
    /// Python: STRUCT_OVERHEAD = 8
    public static let STRUCT_OVERHEAD = 8

    /// Total LXMF overhead per message in bytes
    /// Breakdown: 16 (dest) + 16 (source) + 64 (signature) + 8 (timestamp) + 8 (struct) = 112
    /// Python: LXMF_OVERHEAD = 2*DESTINATION_LENGTH + SIGNATURE_LENGTH + TIMESTAMP_SIZE + STRUCT_OVERHEAD
    public static let LXMF_OVERHEAD = 112

    // MARK: - Maximum Content Sizes

    /// Maximum data unit for encrypted RNS packets
    /// Python: ENCRYPTED_PACKET_MDU = RNS.Packet.ENCRYPTED_MDU + TIMESTAMP_SIZE
    /// With MTU=500, RNS.Packet.ENCRYPTED_MDU = 391, so this = 399
    public static let ENCRYPTED_PACKET_MDU = 399

    /// Maximum content size in single opportunistic packet
    /// We infer destination hash from packet header, so we add DESTINATION_LENGTH back.
    /// Python: ENCRYPTED_PACKET_MAX_CONTENT = ENCRYPTED_PACKET_MDU - LXMF_OVERHEAD + DESTINATION_LENGTH
    /// = 399 - 112 + 16 = 303
    ///
    /// NOTE: Python implementation has a comment saying 295 bytes, but the calculation
    /// yields 303. Using the calculated value to match actual behavior.
    public static let ENCRYPTED_PACKET_MAX_CONTENT = 303

    /// Maximum data unit for packets over established links
    /// Python: LINK_PACKET_MDU = RNS.Link.MDU = 431
    public static let LINK_PACKET_MDU = 431

    /// Maximum content size in single packet over link
    /// Python: LINK_PACKET_MAX_CONTENT = LINK_PACKET_MDU - LXMF_OVERHEAD
    /// = 431 - 112 = 319
    public static let LINK_PACKET_MAX_CONTENT = 319

    /// Maximum content size for resource-based transfers
    /// Python: No explicit limit, uses Int.max
    public static let RESOURCE_MAX_CONTENT = Int.max

    /// Maximum data unit for plain (unencrypted) packets
    /// Python: PLAIN_PACKET_MDU = RNS.Packet.PLAIN_MDU = 464
    public static let PLAIN_PACKET_MDU = 464

    /// Maximum content size in plain packet
    /// Python: PLAIN_PACKET_MAX_CONTENT = PLAIN_PACKET_MDU - LXMF_OVERHEAD + DESTINATION_LENGTH
    /// = 464 - 112 + 16 = 368
    public static let PLAIN_PACKET_MAX_CONTENT = 368

    // MARK: - Link Establishment

    /// Timeout for link establishment in seconds.
    /// Default 30 seconds allows for multi-hop path establishment.
    /// Reference: RNS Link.ESTABLISHMENT_TIMEOUT_PER_HOP = 6 seconds
    public static let LINK_ESTABLISHMENT_TIMEOUT: TimeInterval = 30.0

    // MARK: - Encryption Descriptions

    /// AES-128 encryption description
    public static let ENCRYPTION_DESCRIPTION_AES = "AES-128"

    /// Curve25519 ECDH encryption description
    public static let ENCRYPTION_DESCRIPTION_EC = "Curve25519"

    /// Unencrypted message description
    public static let ENCRYPTION_DESCRIPTION_UNENCRYPTED = "Unencrypted"
}
