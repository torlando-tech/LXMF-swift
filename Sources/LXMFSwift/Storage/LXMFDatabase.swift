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

    private let dbQueue: DatabaseQueue

    // MARK: - Initialization

    /// Create or open LXMF database.
    ///
    /// - Parameter path: Database file path (use ":memory:" for in-memory)
    /// - Throws: DatabaseError if initialization fails
    public init(path: String) throws {
        // Configure database
        var config = Configuration()
        config.prepareDatabase { db in
            // Enable WAL mode for concurrent access
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            // Set synchronous mode to NORMAL for better performance
            try db.execute(sql: "PRAGMA synchronous=NORMAL")
        }

        // Create database queue
        dbQueue = try DatabaseQueue(path: path, configuration: config)

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

        try migrator.migrate(dbQueue)
    }

    // MARK: - Message Operations

    /// Save message to database.
    ///
    /// Creates or updates conversation record based on message.
    ///
    /// - Parameter message: LXMessage to save (must be packed)
    /// - Throws: DatabaseError or LXMFError if save fails
    public func saveMessage(_ message: LXMessage) throws {
        try dbQueue.write { db in
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
        try dbQueue.read { db in
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
        try dbQueue.read { db in
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
        try dbQueue.read { db in
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
        try dbQueue.write { db in
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
        try dbQueue.read { db in
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
        try dbQueue.read { db in
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
        try dbQueue.write { db in
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
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM conversations WHERE destination_hash = ?",
                arguments: [hash]
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
        try dbQueue.write { db in
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

    /// Update conversation for message.
    ///
    /// Creates conversation if it doesn't exist, updates if it does.
    ///
    /// - Parameter message: Message to update conversation for
    /// - Throws: DatabaseError
    public func updateConversation(for message: LXMessage) throws {
        try dbQueue.write { db in
            try updateConversationForMessage(message, in: db)
        }
    }

    /// Load pending outbound messages.
    ///
    /// Returns messages in OUTBOUND state for router to send.
    ///
    /// - Returns: Array of LXMessage
    /// - Throws: DatabaseError or LXMFError
    public func loadPendingOutbound() throws -> [LXMessage] {
        try dbQueue.read { db in
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
        try dbQueue.read { db in
            let records = try MessageRecord
                .filter(Column("state") == LXMessageState.failed.rawValue)
                .order(Column("timestamp").desc)
                .fetchAll(db)

            return try records.map { try $0.toLXMessage() }
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

            // Update existing conversation
            conversation.lastMessageTimestamp = message.timestamp
            conversation.updatedAt = Date().timeIntervalSince1970

            // Generate preview (first 100 chars of content as UTF-8 string)
            if let contentStr = String(data: message.content, encoding: .utf8) {
                let preview = String(contentStr.prefix(100))
                conversation.lastMessagePreview = preview
            }

            // Increment unread count if incoming
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
