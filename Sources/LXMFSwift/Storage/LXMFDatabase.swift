//
//  LXMFDatabase.swift
//  LXMFSwift
//
//  SQLite database for persisting LXMF messages and conversations using GRDB.
//  Configured with WAL mode for concurrent access between app and Network Extension.
//

import Foundation
import GRDB

/// Actor for thread-safe LXMF message database operations.
///
/// Manages SQLite database with WAL mode for concurrent access.
/// Stores messages with full wire format for retransmission.
public actor LXMFDatabase {
    // MARK: - Properties

    private let dbPool: DatabasePool

    // MARK: - Initialization

    /// Create or open LXMF database.
    ///
    /// - Parameter path: Database file path
    /// - Throws: DatabaseError if initialization fails
    public init(path: String) throws {
        // Configure database
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable WAL mode for concurrent reads during writes
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            // Set synchronous mode to NORMAL for better performance
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
            // Retry for up to 5 seconds if the database is locked
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }

        // Create database pool (allows concurrent reads during writes in WAL mode)
        dbPool = try DatabasePool(path: path, configuration: config)

        // Run migrations
        var migrator = DatabaseMigrator()

        // v1: Initial schema
        migrator.registerMigration("v1_initial") { db in
            // Create conversations table
            try db.create(table: "conversations") { t in
                t.column("destination_hash", .blob).primaryKey().notNull()
                t.column("display_name", .text)
                t.column("last_message_timestamp", .double)
                t.column("last_message_preview", .text)
                t.column("unread_count", .integer).defaults(to: 0)
                t.column("is_unread", .integer).defaults(to: 0)
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }

            // Create messages table
            try db.create(table: "messages") { t in
                t.column("message_id", .blob).primaryKey().notNull()
                t.column("conversation_hash", .blob).notNull()
                    .references("conversations", column: "destination_hash", onDelete: .cascade)
                t.column("destination_hash", .blob).notNull()
                t.column("source_hash", .blob).notNull()
                t.column("signature", .blob).notNull()
                t.column("timestamp", .double).notNull()
                t.column("title", .blob)
                t.column("content", .blob).notNull()
                t.column("fields", .blob)
                t.column("stamp", .blob)
                t.column("state", .integer).notNull()
                t.column("method", .integer).notNull()
                t.column("delivery_attempts", .integer).defaults(to: 0)
                t.column("progress", .double).defaults(to: 0.0)
                t.column("incoming", .integer).notNull()
                t.column("rssi", .double)
                t.column("snr", .double)
                t.column("q", .double)
                t.column("ratchet_id", .blob)
                t.column("packed_lxmf", .blob).notNull()
                t.column("created_at", .double).notNull()
                t.column("updated_at", .double).notNull()
            }

            // Create indexes for fast queries
            try db.create(index: "idx_messages_conversation_timestamp",
                         on: "messages",
                         columns: ["conversation_hash", "timestamp"])
            try db.create(index: "idx_messages_state",
                         on: "messages",
                         columns: ["state"])
            try db.create(index: "idx_messages_timestamp",
                         on: "messages",
                         columns: ["timestamp"])
            try db.create(index: "idx_conversations_last_timestamp",
                         on: "conversations",
                         columns: ["last_message_timestamp"])
        }

        // v2: Add is_favorite column to conversations
        migrator.registerMigration("v2_add_favorite") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "is_favorite", .integer).defaults(to: 0)
            }
        }

        // v3: Add icon appearance columns to conversations
        migrator.registerMigration("v3_add_icon_appearance") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "icon_name", .text)
                t.add(column: "icon_fg_color", .text)
                t.add(column: "icon_bg_color", .text)
            }
        }

        // v4: Add receiving_interface column to messages
        migrator.registerMigration("v4_add_receiving_interface") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "receiving_interface", .text)
            }
        }

        // v5: Add is_pinned column to conversations
        migrator.registerMigration("v5_add_pinned") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "is_pinned", .integer).defaults(to: 0)
            }
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - Message Operations

    /// Save message to database.
    ///
    /// Creates or updates conversation record based on message.
    ///
    /// - Parameter message: LXMessage to save (must be packed)
    /// - Throws: DatabaseError or LXMFError if save fails
    public func saveMessage(_ message: LXMessage) throws {
        try dbPool.write { db in
            // Update/create conversation FIRST (foreign key requires it)
            try self.updateConversationForMessage(message, in: db)

            // Create message record
            let record = try MessageRecord(from: message)

            // Save message (insert or replace)
            try record.save(db)
        }
    }

    /// Get message by ID.
    ///
    /// - Parameter id: Message hash (32 bytes)
    /// - Returns: LXMessage if found, nil otherwise
    /// - Throws: DatabaseError or LXMFError if retrieval fails
    public func getMessage(id: Data) throws -> LXMessage? {
        try dbPool.read { db in
            guard let record = try MessageRecord
                .filter(Column("message_id") == id)
                .fetchOne(db) else {
                return nil
            }
            return try record.toLXMessage()
        }
    }

    /// Check if message exists.
    ///
    /// - Parameter id: Message hash (32 bytes)
    /// - Returns: True if message exists
    /// - Throws: DatabaseError
    public func hasMessage(id: Data) throws -> Bool {
        try dbPool.read { db in
            try MessageRecord
                .filter(Column("message_id") == id)
                .fetchCount(db) > 0
        }
    }

    /// Get messages for conversation.
    ///
    /// Returns messages ordered by timestamp descending (newest first).
    ///
    /// - Parameters:
    ///   - hash: Conversation destination hash (16 bytes)
    ///   - limit: Maximum number of messages to return
    ///   - offset: Number of messages to skip
    /// - Returns: Array of LXMessage
    /// - Throws: DatabaseError or LXMFError
    public func getMessages(forConversation hash: Data, limit: Int = 50, offset: Int = 0) throws -> [LXMessage] {
        try dbPool.read { db in
            let records = try MessageRecord
                .filter(Column("conversation_hash") == hash)
                .order(Column("timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)

            return try records.map { try $0.toLXMessage() }
        }
    }

    /// Update message state.
    ///
    /// - Parameters:
    ///   - id: Message hash (32 bytes)
    ///   - state: New state
    /// - Throws: DatabaseError
    public func updateMessageState(id: Data, state: LXMessageState) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE messages SET state = ?, updated_at = ? WHERE message_id = ?",
                arguments: [state.rawValue, Date().timeIntervalSince1970, id]
            )
        }
    }

    /// Get all conversations.
    ///
    /// Returns conversations ordered by last message timestamp descending.
    ///
    /// - Parameters:
    ///   - limit: Maximum number of conversations to return
    ///   - offset: Number of conversations to skip
    /// - Returns: Array of ConversationRecord
    /// - Throws: DatabaseError
    public func getConversations(limit: Int = 100, offset: Int = 0) throws -> [ConversationRecord] {
        try dbPool.read { db in
            try ConversationRecord
                .order(Column("last_message_timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Get single conversation by destination hash.
    ///
    /// - Parameter hash: Destination hash (16 bytes)
    /// - Returns: ConversationRecord if found, nil otherwise
    /// - Throws: DatabaseError
    public func getConversation(hash: Data) throws -> ConversationRecord? {
        try dbPool.read { db in
            try ConversationRecord
                .filter(Column("destination_hash") == hash)
                .fetchOne(db)
        }
    }

    /// Mark conversation as read.
    ///
    /// Resets unread count and is_unread flag, updates timestamp.
    ///
    /// - Parameter hash: Destination hash (16 bytes)
    /// - Throws: DatabaseError
    public func markConversationRead(hash: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET unread_count = 0, is_unread = 0, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Delete conversation and all its messages.
    ///
    /// Messages are automatically deleted via CASCADE foreign key constraint.
    ///
    /// - Parameter hash: Destination hash (16 bytes)
    /// - Throws: DatabaseError
    public func deleteConversation(hash: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM conversations WHERE destination_hash = ?",
                arguments: [hash]
            )
        }
    }

    /// Delete a single message by its ID hash.
    ///
    /// - Parameter messageId: Message hash (32 bytes)
    /// - Throws: DatabaseError
    public func deleteMessage(id messageId: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE message_id = ?",
                arguments: [messageId]
            )
        }
    }

    /// Ensure a conversation exists for a destination.
    ///
    /// Creates a new conversation record if one doesn't exist.
    /// If conversation already exists, updates the display name if provided and not already set.
    ///
    /// - Parameters:
    ///   - hash: Destination hash (16 bytes)
    ///   - displayName: Display name for the conversation (optional)
    /// - Throws: DatabaseError
    public func ensureConversation(hash: Data, displayName: String?) throws {
        try dbPool.write { db in
            if var conversation = try ConversationRecord
                .filter(Column("destination_hash") == hash)
                .fetchOne(db) {
                // Update display name if not already set and we have one
                if conversation.displayName == nil, let displayName = displayName {
                    conversation.displayName = displayName
                    conversation.updatedAt = Date().timeIntervalSince1970
                    try conversation.update(db)
                }
            } else {
                // Create new conversation
                let conversation = ConversationRecord(
                    destinationHash: hash,
                    displayName: displayName,
                    lastMessageTimestamp: Date().timeIntervalSince1970,
                    lastMessagePreview: nil,
                    unreadCount: 0
                )
                try conversation.insert(db)
            }
        }
    }

    /// Set pinned status for a conversation.
    ///
    /// - Parameters:
    ///   - hash: Destination hash (16 bytes)
    ///   - isPinned: Whether to pin the conversation
    /// - Throws: DatabaseError
    public func setPinned(hash: Data, isPinned: Bool) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET is_pinned = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [isPinned ? 1 : 0, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Update display name for a conversation.
    ///
    /// - Parameters:
    ///   - hash: Destination hash (16 bytes)
    ///   - displayName: New display name (nil to clear)
    /// - Throws: DatabaseError
    public func updateDisplayName(hash: Data, displayName: String?) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET display_name = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [displayName, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Set favorite status for a conversation.
    ///
    /// - Parameters:
    ///   - hash: Destination hash (16 bytes)
    ///   - isFavorite: Whether to mark as favorite
    /// - Throws: DatabaseError
    public func setFavorite(hash: Data, isFavorite: Bool) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET is_favorite = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [isFavorite ? 1 : 0, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Update conversation for message.
    ///
    /// Creates conversation if it doesn't exist, updates if it does.
    ///
    /// - Parameter message: Message to update conversation for
    /// - Throws: DatabaseError
    public func updateConversation(for message: LXMessage) throws {
        try dbPool.write { db in
            try updateConversationForMessage(message, in: db)
        }
    }

    /// Get raw message records for conversation (no LXMessage unpacking).
    ///
    /// Returns lightweight MessageRecord structs directly from database,
    /// avoiding expensive MessagePack decode + SHA256 + Ed25519 verification.
    /// Use this for UI display paths where only metadata is needed.
    ///
    /// - Parameters:
    ///   - hash: Conversation destination hash (16 bytes)
    ///   - limit: Maximum number of records to return
    ///   - offset: Number of records to skip
    /// - Returns: Array of MessageRecord
    /// - Throws: DatabaseError
    public func getMessageRecords(forConversation hash: Data, limit: Int = 200, offset: Int = 0) throws -> [MessageRecord] {
        try dbPool.read { db in
            try MessageRecord
                .filter(Column("conversation_hash") == hash)
                .order(Column("timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Load pending outbound messages.
    ///
    /// Returns messages in OUTBOUND state for router to send.
    ///
    /// - Returns: Array of LXMessage
    /// - Throws: DatabaseError or LXMFError
    public func loadPendingOutbound() throws -> [LXMessage] {
        try dbPool.read { db in
            let records = try MessageRecord
                .filter(Column("state") == LXMessageState.outbound.rawValue)
                .order(Column("timestamp").asc)
                .fetchAll(db)

            return try records.map { try $0.toLXMessage() }
        }
    }

    /// Load failed outbound messages.
    ///
    /// Returns messages in FAILED state for retry or inspection.
    ///
    /// - Returns: Array of LXMessage
    /// - Throws: DatabaseError or LXMFError
    public func loadFailedOutbound() throws -> [LXMessage] {
        try dbPool.read { db in
            let records = try MessageRecord
                .filter(Column("state") == LXMessageState.failed.rawValue)
                .order(Column("timestamp").desc)
                .fetchAll(db)

            return try records.map { try $0.toLXMessage() }
        }
    }

    // MARK: - Icon Appearance

    /// Update peer icon appearance for a conversation.
    ///
    /// - Parameters:
    ///   - hash: Destination hash (16 bytes)
    ///   - iconName: MDI icon name
    ///   - fgColor: Foreground color hex (6 chars)
    ///   - bgColor: Background color hex (6 chars)
    /// - Throws: DatabaseError
    public func updatePeerIcon(_ hash: Data, iconName: String, fgColor: String, bgColor: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET icon_name = ?, icon_fg_color = ?, icon_bg_color = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [iconName, fgColor, bgColor, Date().timeIntervalSince1970, hash]
            )
        }
    }

    /// Get peer icon appearance for a conversation.
    ///
    /// - Parameter hash: Destination hash (16 bytes)
    /// - Returns: IconAppearance if set, nil otherwise
    /// - Throws: DatabaseError
    public func getPeerIcon(_ hash: Data) throws -> IconAppearance? {
        try dbPool.read { db in
            guard let record = try ConversationRecord
                .filter(Column("destination_hash") == hash)
                .fetchOne(db) else { return nil }
            guard let name = record.iconName,
                  let fg = record.iconFgColor,
                  let bg = record.iconBgColor else { return nil }
            return IconAppearance(iconName: name, foregroundColor: fg, backgroundColor: bg)
        }
    }

    // MARK: - Private Helpers

    /// Update conversation record for message (internal helper).
    ///
    /// - Parameters:
    ///   - message: Message to update conversation for
    ///   - db: Database connection
    /// - Throws: DatabaseError
    private func updateConversationForMessage(_ message: LXMessage, in db: Database) throws {
        let conversationHash = message.incoming ? message.sourceHash : message.destinationHash

        // Try to fetch existing conversation
        if var conversation = try ConversationRecord
            .filter(Column("destination_hash") == conversationHash)
            .fetchOne(db) {

            // Only update preview/timestamp if this message is newer (or equal).
            // This prevents an older outbound save from overwriting a newer
            // incoming message's preview when saves race.
            if message.timestamp >= conversation.lastMessageTimestamp {
                conversation.lastMessageTimestamp = message.timestamp
                conversation.updatedAt = Date().timeIntervalSince1970

                // Generate preview (first 100 chars of content as UTF-8 string).
                // Skip empty content (e.g. telemetry-only messages) to preserve previous preview.
                if !message.content.isEmpty,
                   let contentStr = String(data: message.content, encoding: .utf8),
                   !contentStr.isEmpty {
                    conversation.lastMessagePreview = String(contentStr.prefix(100))
                }
            }

            // Increment unread count if incoming (regardless of timestamp)
            if message.incoming {
                conversation.unreadCount += 1
                conversation.isUnread = 1
            }

            try conversation.update(db)
        } else {
            // Create new conversation
            let preview = String(data: message.content, encoding: .utf8).map { String($0.prefix(100)) }

            let conversation = ConversationRecord(
                destinationHash: conversationHash,
                displayName: nil,
                lastMessageTimestamp: message.timestamp,
                lastMessagePreview: preview,
                unreadCount: message.incoming ? 1 : 0
            )

            try conversation.insert(db)
        }
    }
}
