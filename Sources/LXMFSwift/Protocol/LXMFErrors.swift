//
//  LXMFErrors.swift
//  LXMFSwift
//
//  LXMF error types for message operations.
//

import Foundation

/// Errors that can occur during LXMF message operations.
public enum LXMFError: Error, Sendable {
    /// Failed to unpack LXMF message from wire format
    case unpackFailed(String)

    /// Message signature validation failed
    case invalidSignature

    /// No source identity for signing outbound message
    case noSourceIdentity

    /// Invalid message format during unpacking
    case invalidMessageFormat(String)

    /// Proof-of-work stamp validation failed
    case stampValidationFailed

    /// No path available to destination
    case noPath

    /// Link establishment or operation failed
    case linkFailed(String)

    /// Maximum retry attempts exceeded
    case maxAttemptsExceeded

    /// Invalid message state transition
    case invalidStateTransition(from: LXMessageState, to: LXMessageState)

    /// Content exceeds maximum size for delivery method
    case contentTooLarge(size: Int, maxSize: Int, method: LXDeliveryMethod)

    /// Invalid destination hash
    case invalidDestination

    /// Invalid source identity
    case invalidSource

    /// Message encoding failed
    case encodingFailed(String)

    /// Message decoding failed
    case decodingFailed(String)

    /// Required field missing from message
    case missingField(String)

    /// Database operation failed
    case databaseError(String)

    /// Message not packed (must call pack() first)
    case notPacked

    /// Propagation node not configured
    case propagationNodeNotSet

    /// Propagation delivery or sync failed
    case propagationFailed(String)

    /// Sync from propagation node failed
    case syncFailed(String)
}

extension LXMFError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unpackFailed(let detail):
            return "Failed to unpack LXMF message: \(detail)"
        case .invalidSignature:
            return "Message signature validation failed"
        case .noSourceIdentity:
            return "No source identity available for signing message"
        case .invalidMessageFormat(let detail):
            return "Invalid message format: \(detail)"
        case .stampValidationFailed:
            return "Proof-of-work stamp validation failed"
        case .noPath:
            return "No path available to destination"
        case .linkFailed(let detail):
            return "Link operation failed: \(detail)"
        case .maxAttemptsExceeded:
            return "Maximum delivery attempts exceeded"
        case .invalidStateTransition(let from, let to):
            return "Invalid state transition from \(from) to \(to)"
        case .contentTooLarge(let size, let maxSize, let method):
            return "Content size \(size) exceeds maximum \(maxSize) for \(method) delivery"
        case .invalidDestination:
            return "Invalid destination hash"
        case .invalidSource:
            return "Invalid source identity"
        case .encodingFailed(let detail):
            return "Message encoding failed: \(detail)"
        case .decodingFailed(let detail):
            return "Message decoding failed: \(detail)"
        case .missingField(let field):
            return "Required field missing: \(field)"
        case .databaseError(let detail):
            return "Database operation failed: \(detail)"
        case .notPacked:
            return "Message not packed (must call pack() first)"
        case .propagationNodeNotSet:
            return "Propagation node not configured"
        case .propagationFailed(let detail):
            return "Propagation delivery failed: \(detail)"
        case .syncFailed(let detail):
            return "Sync from propagation node failed: \(detail)"
        }
    }
}
