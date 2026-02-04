//
//  LXMessageState.swift
//  LXMFSwift
//
//  LXMF message state, representation, and delivery method enumerations.
//  These values must match the Python LXMF implementation exactly.
//
//  Reference: LXMF/LXMessage.py lines 14-37
//

import Foundation

/// LXMF message state enumeration.
///
/// These values must match the Python LXMF implementation exactly for
/// byte-perfect interoperability and database serialization.
///
/// Reference: LXMF/LXMessage.py lines 14-22
public enum LXMessageState: UInt8, Codable, Sendable {
    /// Message is being constructed (not yet ready to send)
    /// Python: GENERATING = 0x00
    case generating = 0x00

    /// Message is ready to send (queued for outbound)
    /// Python: OUTBOUND = 0x01
    case outbound = 0x01

    /// Message is actively being transmitted
    /// Python: SENDING = 0x02
    case sending = 0x02

    /// Message successfully sent to transport
    /// Python: SENT = 0x04
    case sent = 0x04

    /// Message delivered to destination (delivery receipt received)
    /// Python: DELIVERED = 0x08
    case delivered = 0x08

    /// Message rejected by recipient (unused in client mode)
    /// Python: REJECTED = 0xFD
    case rejected = 0xFD

    /// Message cancelled by sender before delivery
    /// Python: CANCELLED = 0xFE
    case cancelled = 0xFE

    /// Message delivery failed after all retry attempts
    /// Python: FAILED = 0xFF
    case failed = 0xFF
}

/// LXMF message representation type.
///
/// Indicates how the message is represented for transport.
///
/// Reference: LXMF/LXMessage.py lines 24-27
public enum LXMessageRepresentation: UInt8, Codable, Sendable {
    /// Representation not yet determined
    /// Python: UNKNOWN = 0x00
    case unknown = 0x00

    /// Message sent as single packet
    /// Python: PACKET = 0x01
    case packet = 0x01

    /// Message sent as RNS resource (multi-packet transfer)
    /// Python: RESOURCE = 0x02
    case resource = 0x02
}

/// LXMF message delivery method.
///
/// These values must match the Python LXMF implementation exactly.
///
/// Reference: LXMF/LXMessage.py lines 29-33
public enum LXDeliveryMethod: UInt8, Codable, Sendable {
    /// Opportunistic delivery (single packet, no link required)
    /// Best effort delivery without establishing a link.
    /// Python: OPPORTUNISTIC = 0x01
    case opportunistic = 0x01

    /// Direct delivery over established link
    /// Requires establishing a link to the destination first.
    /// Python: DIRECT = 0x02
    case direct = 0x02

    /// Propagated delivery via propagation nodes
    /// Message stored at intermediate nodes for later retrieval.
    /// Python: PROPAGATED = 0x03
    case propagated = 0x03

    /// Paper message (QR code or physical medium)
    /// For completely offline message transfer.
    /// Python: PAPER = 0x05
    case paper = 0x05
}

/// LXMF unverified reason codes.
///
/// Indicates why a message signature could not be verified.
///
/// Reference: LXMF/LXMessage.py lines 35-37
public enum LXUnverifiedReason: UInt8, Codable, Sendable {
    /// Source identity unknown (no public key available)
    /// Python: SOURCE_UNKNOWN = 0x01
    case sourceUnknown = 0x01

    /// Signature validation failed
    /// Python: SIGNATURE_INVALID = 0x02
    case signatureInvalid = 0x02
}
