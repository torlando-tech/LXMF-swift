//
//  ConversationRecord.swift
//  LXMFSwift
//
//  GRDB record for persisting LXMF conversations to SQLite.
//  Tracks conversation metadata for fast list queries.
//

import Foundation
import GRDB

/// Database record for LXMF conversations.
///
/// Aggregates messages by destination hash and tracks metadata
/// for efficient conversation list UI rendering.
public struct ConversationRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "conversations"

    // MARK: - Database Columns

    /// Destination hash (16 bytes) - primary key
    public var destinationHash: Data

    /// Display name (optional, user-provided)
    public var displayName: String?

    /// Timestamp of most recent message
    public var lastMessageTimestamp: Double

    /// Preview text of most recent message
    public var lastMessagePreview: String?

    /// Count of unread messages
    public var unreadCount: Int

    /// Legacy flag (1 if unread, 0 if read) - for compatibility
    public var isUnread: Int

    /// Record creation timestamp
    public var createdAt: Double

    /// Record update timestamp
    public var updatedAt: Double

    /// Whether this conversation is marked as favorite/saved contact
    public var isFavorite: Int

    /// MDI icon name for peer's profile icon (from LXMF Field 4)
    public var iconName: String?

    /// Foreground color hex for peer's icon (6 chars, e.g., "FFFFFF")
    public var iconFgColor: String?

    /// Background color hex for peer's icon (6 chars, e.g., "1E88E5")
    public var iconBgColor: String?

    // MARK: - Column Mapping (snake_case to camelCase)

    enum CodingKeys: String, CodingKey {
        case destinationHash = "destination_hash"
        case displayName = "display_name"
        case lastMessageTimestamp = "last_message_timestamp"
        case lastMessagePreview = "last_message_preview"
        case unreadCount = "unread_count"
        case isUnread = "is_unread"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isFavorite = "is_favorite"
        case iconName = "icon_name"
        case iconFgColor = "icon_fg_color"
        case iconBgColor = "icon_bg_color"
    }

    // MARK: - Computed Properties

    /// True if conversation has unread messages
    public var hasUnreadMessages: Bool {
        return unreadCount > 0
    }

    // MARK: - Initialization

    /// Create new conversation record.
    public init(
        destinationHash: Data,
        displayName: String? = nil,
        lastMessageTimestamp: Double,
        lastMessagePreview: String? = nil,
        unreadCount: Int = 0,
        isFavorite: Bool = false
    ) {
        self.destinationHash = destinationHash
        self.displayName = displayName
        self.lastMessageTimestamp = lastMessageTimestamp
        self.lastMessagePreview = lastMessagePreview
        self.unreadCount = unreadCount
        self.isUnread = unreadCount > 0 ? 1 : 0
        self.isFavorite = isFavorite ? 1 : 0

        let now = Date().timeIntervalSince1970
        self.createdAt = now
        self.updatedAt = now
    }
}
