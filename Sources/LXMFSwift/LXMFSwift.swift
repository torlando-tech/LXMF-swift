//
//  LXMFSwift.swift
//  LXMFSwift
//
//  Re-export file for LXMFSwift package.
//  Apps importing LXMFSwift automatically get access to ReticulumSwift types.
//
//  Usage:
//  ```swift
//  import LXMFSwift
//  // Now you have access to both LXMF and Reticulum types
//  ```
//

import Foundation

// Re-export ReticulumSwift so consumers don't need to import both packages
@_exported import ReticulumSwift

// MARK: - LXMF Types

// Message types
// - LXMessage: LXMF message structure
// - LXMessageState: Message delivery state
// - LXMessageRepresentation: Packet vs Resource
// - LXDeliveryMethod: Opportunistic, Direct, Propagated
// - LXUnverifiedReason: Signature verification failure reason

// Router types
// - LXMRouter: LXMF message router actor
// - LXMRouterDelegate: Message delivery callbacks
// - PhysicalStats: RSSI, SNR, Q from physical layer

// Storage types
// - LXMFDatabase: SQLite message persistence
// - ConversationRecord: Conversation metadata
// - MessageRecord: Full message persistence

// Protocol types
// - LXMFConstants: Wire format constants
// - LXMFError: Error types
// - LXMFMessagePackValue: MessagePack encoding
// - LXStamper: Proof-of-work stamps

// MARK: - Version

/// LXMFSwift version string
public let LXMFSwiftVersion = "0.1.0"

/// LXMFSwift build info
public struct LXMFSwiftBuild {
    /// Package name
    public static let name = "LXMFSwift"

    /// Package version
    public static let version = LXMFSwiftVersion

    /// Swift protocol version (matches Python LXMF)
    public static let protocolVersion = "0.5"

    /// Build date (set at compile time)
    public static let buildDate = Date()
}
