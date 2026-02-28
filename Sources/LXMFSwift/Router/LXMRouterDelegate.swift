//
//  LXMRouterDelegate.swift
//  LXMFSwift
//
//  Delegate protocol for LXMRouter events.
//  Callbacks are invoked when messages are received, state changes, or failures occur.
//
//  Reference: Python LXMF delivery_callback and state change patterns
//

import Foundation

/// Delegate protocol for LXMRouter message delivery and state change events.
///
/// All delegate methods are called on the main actor to ensure UI-safe access.
/// Callbacks are invoked for incoming messages, outbound state changes, and failures.
@MainActor
public protocol LXMRouterDelegate: AnyObject, Sendable {

    /// Called when a message is received and validated.
    ///
    /// The message has already been validated (signature check passed),
    /// duplicate detection passed, stamp validated if required, and stored in database.
    ///
    /// - Parameters:
    ///   - router: The router that received the message
    ///   - message: The validated incoming message
    func router(_ router: LXMRouter, didReceiveMessage message: LXMessage)

    /// Called when an outbound message state changes.
    ///
    /// This is invoked for state transitions during delivery attempts,
    /// such as OUTBOUND -> SENDING -> SENT -> DELIVERED.
    ///
    /// - Parameters:
    ///   - router: The router managing the message
    ///   - message: The message with updated state
    func router(_ router: LXMRouter, didUpdateMessage message: LXMessage)

    /// Called when an outbound message delivery fails.
    ///
    /// This is invoked when all retry attempts are exhausted or
    /// the message is rejected/cancelled.
    ///
    /// - Parameters:
    ///   - router: The router managing the message
    ///   - message: The failed message
    ///   - reason: The error causing failure
    func router(_ router: LXMRouter, didFailMessage message: LXMessage, reason: LXMFError)

    /// Called when a delivery proof is received for a sent message.
    ///
    /// This indicates the recipient has received the message. The message's
    /// state has been updated to `.delivered` in the database.
    ///
    /// - Parameters:
    ///   - router: The router managing the message
    ///   - messageHash: The hash of the delivered message (32 bytes)
    func router(_ router: LXMRouter, didConfirmDelivery messageHash: Data)

    /// Called when propagation sync state changes.
    ///
    /// Provides progress updates during sync operations for UI display.
    ///
    /// - Parameters:
    ///   - router: The router performing the sync
    ///   - state: Current sync transfer state
    func router(_ router: LXMRouter, didUpdateSyncState state: PropagationTransferState)

    /// Called when propagation sync completes.
    ///
    /// - Parameters:
    ///   - router: The router that completed sync
    ///   - newMessages: Number of new messages received
    func router(_ router: LXMRouter, didCompleteSyncWithNewMessages newMessages: Int)
}

/// Default implementations for optional delegate methods.
///
/// Provides empty implementations so conformers only need to implement
/// the callbacks they care about.
@MainActor
public extension LXMRouterDelegate {
    func router(_ router: LXMRouter, didReceiveMessage message: LXMessage) {
        // Default: no-op
    }

    func router(_ router: LXMRouter, didUpdateMessage message: LXMessage) {
        // Default: no-op
    }

    func router(_ router: LXMRouter, didFailMessage message: LXMessage, reason: LXMFError) {
        // Default: no-op
    }

    func router(_ router: LXMRouter, didConfirmDelivery messageHash: Data) {
        // Default: no-op
    }

    func router(_ router: LXMRouter, didUpdateSyncState state: PropagationTransferState) {
        // Default: no-op
    }

    func router(_ router: LXMRouter, didCompleteSyncWithNewMessages newMessages: Int) {
        // Default: no-op
    }
}
