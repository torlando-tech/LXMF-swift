//
//  PropagationTypes.swift
//  LXMFSwift
//
//  Types for LXMF propagation node support.
//  Defines state machine, transfer state, and node info parsing.
//
//  Reference: LXMF/LXMPeer.py, LXMF/LXMRouter.py propagation announce handling
//

import Foundation

// MARK: - Propagation State

/// State machine for propagation sync operations.
public enum PropagationState: String, Sendable {
    case idle
    case pathRequested
    case linkEstablishing
    case linkEstablished
    case requestSent
    case receiving
    case responseReceived
    case complete

    // Error states
    case noPath
    case linkFailed
    case transferFailed
}

// MARK: - Propagation Transfer State

/// Observable transfer state for UI binding during sync operations.
public struct PropagationTransferState: Sendable {
    /// Current state of the sync operation.
    public var state: PropagationState = .idle

    /// Total messages available on the propagation node.
    public var totalMessages: Int = 0

    /// Messages received so far in current sync.
    public var receivedMessages: Int = 0

    /// Transfer progress (0.0 to 1.0).
    public var progress: Double {
        guard totalMessages > 0 else { return 0.0 }
        return Double(receivedMessages) / Double(totalMessages)
    }

    /// Timestamp of the last successful sync.
    public var lastSync: Date?

    /// Error description if sync failed.
    public var errorDescription: String?

    /// Whether a sync is currently in progress.
    public var isSyncing: Bool {
        switch state {
        case .idle, .complete, .noPath, .linkFailed, .transferFailed:
            return false
        default:
            return true
        }
    }

    public init() {}
}

// MARK: - Propagation Node Info

/// Parsed propagation node information from announce appData.
///
/// Python LXMF propagation nodes announce with a 7-element msgpack array:
/// `[enabled, timebase, isPropagationNode, perTransferLimit, perSyncLimit, stampCost, stampFlexibility]`
///
/// Some implementations extend this with additional fields (peeringCost, metadata).
///
/// Reference: LXMF/LXMRouter.py propagation_announce_handler
public struct PropagationNodeInfo: Sendable {
    /// Whether the propagation node is enabled.
    public let enabled: Bool

    /// Node's timebase (Unix timestamp for sync reference).
    public let timebase: Double

    /// Whether this is a propagation node (element [2]).
    public let isPropagationNode: Bool

    /// Maximum messages per transfer.
    public let perTransferLimit: Int

    /// Maximum messages per sync request.
    public let perSyncLimit: Int

    /// Stamp cost required for message submission (0 = no stamp required).
    public let stampCost: Int

    /// Stamp flexibility (acceptable variance in stamp difficulty).
    public let stampFlexibility: Int

    /// Parse propagation node info from announce appData.
    ///
    /// The appData is a msgpack-encoded array. Element [2] being true
    /// indicates this is a propagation node.
    ///
    /// - Parameter appData: Raw announce application data
    /// - Returns: Parsed info if this is a propagation node, nil otherwise
    public static func parse(from appData: Data) -> PropagationNodeInfo? {
        guard let value = try? unpackLXMF(appData),
              case .array(let elements) = value,
              elements.count >= 3 else {
            return nil
        }

        // Element [2] must be true to indicate propagation node
        guard case .bool(let isPropNode) = elements[2], isPropNode else {
            return nil
        }

        // Element [0] is a legacy field (always False in current Python LXMF).
        // The actual enabled state is element [2] (isPropagationNode), already checked above.
        let enabled = isPropNode

        // Parse timebase
        let timebase: Double
        if case .double(let t) = elements[1] {
            timebase = t
        } else if case .uint(let t) = elements[1] {
            timebase = Double(t)
        } else if case .int(let t) = elements[1] {
            timebase = Double(t)
        } else {
            timebase = 0
        }

        // Parse optional fields with defaults
        let perTransferLimit: Int
        if elements.count > 3, case .uint(let l) = elements[3] {
            perTransferLimit = Int(l)
        } else if elements.count > 3, case .int(let l) = elements[3] {
            perTransferLimit = Int(l)
        } else {
            perTransferLimit = PropagationConstants.DEFAULT_PER_TRANSFER_LIMIT
        }

        let perSyncLimit: Int
        if elements.count > 4, case .uint(let l) = elements[4] {
            perSyncLimit = Int(l)
        } else if elements.count > 4, case .int(let l) = elements[4] {
            perSyncLimit = Int(l)
        } else {
            perSyncLimit = PropagationConstants.DEFAULT_PER_SYNC_LIMIT
        }

        // Element [5] is now a list: [stamp_cost, stamp_cost_flexibility, peering_cost]
        // (Previously was a single int in older LXMF versions)
        let stampCost: Int
        let stampFlexibility: Int
        if elements.count > 5, case .array(let stampArray) = elements[5] {
            if stampArray.count > 0, case .uint(let c) = stampArray[0] { stampCost = Int(c) }
            else if stampArray.count > 0, case .int(let c) = stampArray[0] { stampCost = Int(c) }
            else { stampCost = 0 }
            if stampArray.count > 1, case .uint(let f) = stampArray[1] { stampFlexibility = Int(f) }
            else if stampArray.count > 1, case .int(let f) = stampArray[1] { stampFlexibility = Int(f) }
            else { stampFlexibility = 0 }
        } else if elements.count > 5, case .uint(let c) = elements[5] {
            stampCost = Int(c)
            stampFlexibility = 0
        } else if elements.count > 5, case .int(let c) = elements[5] {
            stampCost = Int(c)
            stampFlexibility = 0
        } else {
            stampCost = 0
            stampFlexibility = 0
        }

        return PropagationNodeInfo(
            enabled: enabled,
            timebase: timebase,
            isPropagationNode: isPropNode,
            perTransferLimit: perTransferLimit,
            perSyncLimit: perSyncLimit,
            stampCost: stampCost,
            stampFlexibility: stampFlexibility
        )
    }
}
