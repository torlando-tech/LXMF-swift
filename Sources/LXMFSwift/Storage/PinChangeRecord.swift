//
//  PinChangeRecord.swift
//  LXMFSwift
//

import Foundation
import GRDB

/// One pin or unpin of a message, ours or the peer's. Kept rather than folded into a message
/// column: the newest change decides the state whatever order they arrive in, each change is its
/// own line in the thread, and a change can wait for a message that hasn't arrived.
public struct PinChangeRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "pin_changes"

    /// The change's LXMF hash; a change delivered twice is one row.
    public let hash: Data
    public let conversationHash: Data
    /// The pinned message's hash.
    public let target: Data
    /// Who made the change: our hash or the peer's.
    public let actor: Data
    public let isPinned: Bool
    /// The change's LXMF timestamp, on the changer's clock.
    public let timestamp: Double
    /// Where its line sits: our clock when we changed it, or when the peer's change arrived.
    public let placedAt: Double

    public init(hash: Data,
                conversationHash: Data,
                target: Data,
                actor: Data,
                isPinned: Bool,
                timestamp: Double,
                placedAt: Double) {
        self.hash = hash
        self.conversationHash = conversationHash
        self.target = target
        self.actor = actor
        self.isPinned = isPinned
        self.timestamp = timestamp
        self.placedAt = placedAt
    }

    enum CodingKeys: String, CodingKey {
        case hash
        case conversationHash = "conversation_hash"
        case target
        case actor
        case isPinned = "is_pinned"
        case timestamp
        case placedAt = "placed_at"
    }
}
