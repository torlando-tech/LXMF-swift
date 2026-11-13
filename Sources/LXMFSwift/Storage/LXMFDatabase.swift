// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

    /// FORK ADDITION. Decides from a message's fields whether it is control traffic rather than
    /// conversation. Such a message is still stored, but it never raises a conversation's unread
    /// count and never moves its preview or timestamp. `nil` (the default) keeps the upstream
    /// behaviour, where everything inbound counts.
    ///
    /// A closure rather than a set of field keys because the same key can carry either kind —
    /// `FIELD_APP_DATA` holds both replies and a legacy client's reactions — so only the host's
    /// own decoders can tell them apart. Called inside the write transaction, so it must stay pure.
    private let isSilentMessage: (@Sendable ([UInt8: Any]?) -> Bool)?

    // MARK: - Initialization

    /// Create or open LXMF database.
    ///
    /// - Parameters:
    ///   - path: Database file path
    ///   - isSilentMessage: see ``isSilentMessage``
    /// - Throws: DatabaseError if initialization fails
    public init(path: String,
                readonly: Bool = false,
                isSilentMessage: (@Sendable ([UInt8: Any]?) -> Bool)? = nil) throws {
        self.isSilentMessage = isSilentMessage
        // App <-> Network-Extension share this database across processes (Model B).
        // The writer (the NE) must survive iOS's 0xDEAD10CC "file busy while suspended"
        // kill; the app opens read-only with `readonly: true`. (GRDB DatabaseSharing.)
        var config = Configuration()
        config.readonly = readonly
        // Suspend cleanly when iOS backgrounds the process holding a lock, instead of
        // being 0xDEAD10CC-killed.
        config.observesSuspensionNotifications = true
        // No `defaultTransactionKind` since GRDB 7: writes already take IMMEDIATE transactions
        // (write locks up front, avoiding cross-process SQLITE_BUSY upgrade deadlocks) and reads
        // DEFERRED — the behaviour this configured by hand under GRDB 6.
        config.prepareDatabase { db in
            if !readonly {
                // Enable WAL mode for concurrent reads during writes
                try db.execute(sql: "PRAGMA journal_mode=WAL")
                // Set synchronous mode to NORMAL for better performance
                try db.execute(sql: "PRAGMA synchronous=NORMAL")
            }
            // Retry for up to 5 seconds if the database is locked
            try db.execute(sql: "PRAGMA busy_timeout=5000")
        }

        // Create database pool (allows concurrent reads during writes in WAL mode)
        dbPool = try DatabasePool(path: path, configuration: config)

        #if os(iOS)
        // Deliver-while-locked: the NE must read/write after first unlock even when the
        // device is subsequently locked. Pin the data-protection class on the DB and its
        // -wal/-shm sidecar files to CompleteUntilFirstUserAuthentication.
        if !readonly {
            let fm = FileManager.default
            for suffix in ["", "-wal", "-shm"] where fm.fileExists(atPath: path + suffix) {
                try? fm.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: path + suffix
                )
            }
        }
        #endif

        // Run migrations. Only the writer runs them: GRDB's migrator issues an
        // internal `write {}` to atomically check/apply schema versions, which
        // returns SQLITE_READONLY (throws) on a read-only pool. Under Model B the
        // writer (the NE) owns the schema; the read-only app reader just opens the
        // already-migrated store, so migrating from it would throw at init before
        // any read could happen.
        if !readonly {
            try Self.makeMigrator().migrate(dbPool)
        }
    }

    /// Builds the schema migrator. Shared between `init` (open + migrate) and
    /// `importDatabase` (forward-migrate a restored snapshot that may have been
    /// taken on an older schema version).
    private static func makeMigrator() -> DatabaseMigrator {
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

        // v6: Add reply and reaction columns to messages
        migrator.registerMigration("v6_add_replies_reactions") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "reply_to_id", .text)
                t.add(column: "reactions_json", .text)
            }
            try db.create(index: "idx_messages_reply_to", on: "messages", columns: ["reply_to_id"])
        }

        // v7: Edit / delete-for-everyone annotations on messages
        migrator.registerMigration("v7_message_annotations") { db in
            try db.alter(table: "messages") { t in
                t.add(column: "edited_content", .blob)
                t.add(column: "edited_at", .double)
                t.add(column: "deleted_at", .double)
            }
        }

        // v8: Pin changes. No foreign key — a change can wait for a message, or a conversation,
        // that hasn't arrived; deleting a conversation or a message removes its rows by hand.
        migrator.registerMigration("v8_kvf_pin_changes") { db in
            try db.create(table: "pin_changes") { t in
                t.column("hash", .blob).primaryKey()
                t.column("conversation_hash", .blob).notNull()
                t.column("target", .blob).notNull()
                t.column("actor", .blob).notNull()
                t.column("is_pinned", .boolean).notNull()
                t.column("timestamp", .double).notNull()
                t.column("placed_at", .double).notNull()
            }
            try db.create(index: "idx_pin_changes_target", on: "pin_changes", columns: ["target"])
            try db.create(index: "idx_pin_changes_actor", on: "pin_changes", columns: ["actor"])
            try db.create(index: "idx_pin_changes_conversation",
                          on: "pin_changes",
                          columns: ["conversation_hash", "placed_at"])
        }

        return migrator
    }

    // MARK: - Backup / Restore

    /// Writes a consistent, self-contained snapshot of the database to `path`
    /// using SQLite `VACUUM INTO`. The result is a single file with no WAL/SHM
    /// sidecars, safe to produce while the database is live (it reads the
    /// committed state, including anything still in the WAL). The destination
    /// file must NOT already exist.
    ///
    /// - Parameter path: Destination file path for the snapshot.
    /// - Throws: DatabaseError if the export fails.
    public func exportDatabase(to path: String) throws {
        try dbPool.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [path])
        }
    }

    /// Replaces the entire contents of this database with the snapshot at
    /// `path`. Copies every page from the source into the live pool, so the
    /// on-disk file and all existing connections (including the router's) keep
    /// pointing at the same path and observe the restored data on their next
    /// transaction — no reopen required. The schema migrator runs afterwards
    /// so a snapshot taken on an older schema version is forward-migrated. All
    /// current conversations and messages are discarded.
    ///
    /// - Parameter path: Source snapshot to restore from.
    /// - Throws: DatabaseError if the source can't be opened or the restore fails.
    public func importDatabase(from path: String) throws {
        let source = try DatabaseQueue(path: path)
        try source.backup(to: dbPool)
        try Self.makeMigrator().migrate(dbPool)
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
            let existing = try MessageRecord.filter(Column("message_id") == message.hash).fetchOne(db)
            // A message deleted for everyone stays erased: the router may still hold the original in
            // memory and re-save it on a state change, which must not bring the content back.
            if existing?.deletedAt != nil {
                try db.execute(sql: "UPDATE messages SET state = ?, updated_at = ? WHERE message_id = ?",
                               arguments: [message.state.rawValue, Date().timeIntervalSince1970, message.hash])
                return
            }

            // Update/create conversation FIRST (foreign key requires it)
            try self.updateConversationForMessage(message, in: db)

            var record = try MessageRecord(from: message)

            // The router re-saves a message on every state change; a plain replace would wipe
            // the annotations (reactions, edits, deletion) that were applied to the row since.
            if let existing {
                record.replyToId = record.replyToId ?? existing.replyToId
                record.reactionsJson = existing.reactionsJson
                record.editedContent = existing.editedContent
                record.editedAt = existing.editedAt
                record.deletedAt = existing.deletedAt
                record.createdAt = existing.createdAt
            }
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
            // A deleted message's packed bytes are erased; there is no message left to unpack.
            guard let record = try MessageRecord
                .filter(Column("message_id") == id)
                .fetchOne(db), record.deletedAt == nil else {
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
                .filter(Column("conversation_hash") == hash && Column("deleted_at") == nil)
                .order(Column("timestamp").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)

            return try records.map { try $0.toLXMessage() }
        }
    }

    /// Count messages in a conversation.
    ///
    /// Answered by SQLite from `idx_messages_conversation_timestamp`, whose leading column is
    /// `conversation_hash` — so this reads the index rather than the rows, and never decodes a
    /// message's content, attachments or packed envelope. Callers that need only the size of a
    /// conversation should use this instead of paging `getMessages(forConversation:limit:offset:)`,
    /// which materialises every blob to arrive at the same number.
    ///
    /// Counts every stored message, both directions, including any the caller would filter out of a
    /// chat view (command envelopes are messages in this table like any other).
    ///
    /// - Parameter hash: Conversation destination hash (16 bytes)
    /// - Returns: Number of stored messages, 0 if the conversation is unknown
    /// - Throws: DatabaseError
    public func countMessages(forConversation hash: Data) throws -> Int {
        try dbPool.read { db in
            try MessageRecord
                .filter(Column("conversation_hash") == hash)
                .fetchCount(db)
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

    /// Set the unread count for a conversation (e.g. mark as unread with count=1).
    public func setUnreadCount(hash: Data, count: Int) throws {
        try dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE conversations
                    SET unread_count = ?, is_unread = ?, updated_at = ?
                    WHERE destination_hash = ?
                    """,
                arguments: [count, count > 0 ? 1 : 0, Date().timeIntervalSince1970, hash]
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
            try db.execute(sql: "DELETE FROM pin_changes WHERE conversation_hash = ?", arguments: [hash])
        }
    }

    /// Delete a single message by its ID hash, with the pin changes aimed at it.
    ///
    /// Only rows *targeting* the message go: command envelopes are discarded through here too, and
    /// a pin envelope's hash is also its pin change's key.
    ///
    /// - Parameter messageId: Message hash (32 bytes)
    /// - Throws: DatabaseError
    public func deleteMessage(id messageId: Data) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM messages WHERE message_id = ?",
                arguments: [messageId]
            )
            try db.execute(sql: "DELETE FROM pin_changes WHERE target = ?", arguments: [messageId])
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
            // Reload `.outbound` (never-sent, awaiting first send) AND OPPORTUNISTIC or
            // DIRECT messages persisted at `.sent` (sent, awaiting a delivery proof). Under
            // Model B the iOS Network Extension is suspended/jetsammed mid-flight, so a
            // small-packet message awaiting its proof when the NE died must re-enter
            // `pendingOutbound` on relaunch to be re-sent and earn a fresh proof —
            // otherwise its in-memory proof callback (reticulum-swift, non-persisted) is
            // gone and the message stays at a single checkmark forever. Python keeps
            // `pending_outbound` in memory across its long-running process
            // (LXMRouter.py:99); this reload emulates that durability for the jetsam-prone
            // NE. SCOPED to small-packet methods: `.sent` is TERMINAL for PROPAGATED (the
            // propagation node ack'd the upload, no recipient proof is expected — python
            // removes it at LXMRouter.py:2544), so reloading a propagated `.sent` would
            // wrongly re-upload it on every launch. This safely targets only small-packet
            // DIRECT: a DIRECT RESOURCE transfer is persisted at `.outbound` (not `.sent`),
            // so it's caught by the first clause, not double-handled. See port-deviations.md
            // ("processOutbound keep-in-queue ... loadPendingOutbound").
            let records = try MessageRecord
                .filter(
                    Column("state") == LXMessageState.outbound.rawValue
                    || (Column("state") == LXMessageState.sent.rawValue
                        && (Column("method") == LXDeliveryMethod.opportunistic.rawValue
                            || Column("method") == LXDeliveryMethod.direct.rawValue))
                )
                // Erased rows can't be unpacked, and one would fail the whole load at startup.
                .filter(Column("deleted_at") == nil)
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
                .filter(Column("state") == LXMessageState.failed.rawValue && Column("deleted_at") == nil)
                .order(Column("timestamp").desc)
                .fetchAll(db)

            return try records.map { try $0.toLXMessage() }
        }
    }

    // MARK: - Reply & Reaction Operations

    /// Update reply-to ID for a message.
    ///
    /// - Parameters:
    ///   - messageId: Message hash (32 bytes)
    ///   - replyToId: The message ID being replied to
    /// - Throws: DatabaseError
    public func updateReplyToId(messageId: Data, replyToId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE messages SET reply_to_id = ?, updated_at = ? WHERE message_id = ?",
                arguments: [replyToId, Date().timeIntervalSince1970, messageId]
            )
        }
    }

    /// Update reactions JSON for a message.
    ///
    /// - Parameters:
    ///   - messageId: Message hash (32 bytes)
    ///   - reactionsJson: JSON string encoding the reactions
    /// - Throws: DatabaseError
    public func updateReactions(messageId: Data, reactionsJson: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE messages SET reactions_json = ?, updated_at = ? WHERE message_id = ?",
                arguments: [reactionsJson, Date().timeIntervalSince1970, messageId]
            )
        }
    }

    /// Read-modify-write of one message's reactions JSON inside a single transaction, so two
    /// concurrent toggles can't both read the old value and lose one of the updates.
    ///
    /// - Parameters:
    ///   - messageId: Message hash (32 bytes)
    ///   - transform: Given the stored record, returns the new reactions JSON (`nil` = leave the
    ///     row untouched) and a result to hand back to the caller
    /// - Returns: The transform's result, or `nil` if no such message exists
    /// - Throws: DatabaseError
    public func updateReactions<Result: Sendable>(
        messageId: Data,
        _ transform: @Sendable (MessageRecord) -> (reactionsJson: String?, result: Result)
    ) throws -> Result? {
        try dbPool.write { db in
            guard let record = try MessageRecord.filter(Column("message_id") == messageId).fetchOne(db) else {
                return nil
            }
            let outcome = transform(record)
            if let json = outcome.reactionsJson {
                try db.execute(
                    sql: "UPDATE messages SET reactions_json = ?, updated_at = ? WHERE message_id = ?",
                    arguments: [json, Date().timeIntervalSince1970, messageId]
                )
            }
            return outcome.result
        }
    }

    /// Deletes a message for everyone: sets `deleted_at` and erases its content, title, fields,
    /// packed bytes, reply link and reactions, keeping the row as a tombstone. One transaction.
    ///
    /// A pending outbound row is also cancelled so it is never loaded for sending again, and the
    /// conversation's preview is rebuilt from its newest message that still has text.
    ///
    /// - Parameters:
    ///   - messageId: Message hash (32 bytes)
    ///   - deletedAt: When it was deleted, in the deleter's clock
    ///   - isAllowed: Checked against the stored row before anything changes
    /// - Returns: What happened; a second call on a deleted row returns `.alreadyDeleted`
    public func markDeleted(messageId: Data,
                            at deletedAt: Double,
                            isAllowed: @Sendable (MessageRecord) -> Bool = { _ in true }) throws -> MessageDeletionOutcome {
        try dbPool.write { db in
            guard let record = try MessageRecord.filter(Column("message_id") == messageId).fetchOne(db) else {
                return .notFound
            }
            guard record.deletedAt == nil else { return .alreadyDeleted }
            guard isAllowed(record) else { return .notAllowed }

            let pendingStates = [LXMessageState.generating, .outbound, .sending].map(\.rawValue)
            let state = !record.incoming && pendingStates.contains(record.state)
                ? LXMessageState.cancelled.rawValue
                : record.state
            try db.execute(
                sql: """
                UPDATE messages
                SET deleted_at = ?, content = ?, title = ?, fields = NULL, packed_lxmf = ?,
                    reply_to_id = NULL, reactions_json = NULL, edited_content = NULL, edited_at = NULL,
                    state = ?, updated_at = ?
                WHERE message_id = ?
                """,
                arguments: [deletedAt, Data(), Data(), Data(), state, Date().timeIntervalSince1970, messageId]
            )
            let latestText = try Data.fetchOne(
                db,
                sql: """
                SELECT content FROM messages
                WHERE conversation_hash = ? AND deleted_at IS NULL AND length(content) > 0
                ORDER BY timestamp DESC LIMIT 1
                """,
                arguments: [record.conversationHash]
            )
            let preview = latestText.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.prefix(100)) }
            try db.execute(sql: "UPDATE conversations SET last_message_preview = ? WHERE destination_hash = ?",
                           arguments: [preview, record.conversationHash])
            return .deleted
        }
    }

    /// Get reactions JSON for a message.
    ///
    /// - Parameter messageId: Message hash (32 bytes)
    /// - Returns: JSON string if reactions exist, nil otherwise
    /// - Throws: DatabaseError
    public func getReactionsJson(messageId: Data) throws -> String? {
        try dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT reactions_json FROM messages WHERE message_id = ?",
                arguments: [messageId]
            )
        }
    }

    /// Get a single message record by ID (no LXMessage unpacking).
    ///
    /// - Parameter id: Message hash (32 bytes)
    /// - Returns: MessageRecord if found, nil otherwise
    /// - Throws: DatabaseError
    public func getMessageRecord(id: Data) throws -> MessageRecord? {
        try dbPool.read { db in
            try MessageRecord
                .filter(Column("message_id") == id)
                .fetchOne(db)
        }
    }

    // MARK: - Pin Changes

    /// Stores a pin change. Returns `false` when a change with that hash is already stored.
    public func savePinChange(_ change: PinChangeRecord) throws -> Bool {
        try dbPool.write { db in
            try change.insert(db, onConflict: .ignore)
            return db.changesCount > 0
        }
    }

    /// Every change of a conversation, waiting ones included, oldest line place first.
    public func pinChanges(forConversation hash: Data) throws -> [PinChangeRecord] {
        try dbPool.read { db in
            try PinChangeRecord
                .filter(Column("conversation_hash") == hash)
                .order(Column("placed_at"), Column("hash"))
                .fetchAll(db)
        }
    }

    /// Every change aimed at one message.
    public func pinChanges(forTarget target: Data) throws -> [PinChangeRecord] {
        try dbPool.read { db in
            try PinChangeRecord
                .filter(Column("target") == target)
                .order(Column("placed_at"), Column("hash"))
                .fetchAll(db)
        }
    }

    /// The changes shown as lines: those whose message is stored in the same conversation,
    /// a tombstone included. Oldest first.
    public func pinLines(forConversation hash: Data) throws -> [PinChangeRecord] {
        try dbPool.read { db in
            try PinChangeRecord.fetchAll(db, sql: """
                SELECT pin_changes.* FROM pin_changes
                JOIN messages ON messages.message_id = pin_changes.target
                    AND messages.conversation_hash = pin_changes.conversation_hash
                WHERE pin_changes.conversation_hash = ?
                ORDER BY pin_changes.placed_at, pin_changes.hash
                """, arguments: [hash])
        }
    }

    /// Each conversation's newest line.
    public func latestPinLines() throws -> [PinChangeRecord] {
        let lines = try dbPool.read { db in
            try PinChangeRecord.fetchAll(db, sql: """
                SELECT pin_changes.* FROM pin_changes
                JOIN messages ON messages.message_id = pin_changes.target
                    AND messages.conversation_hash = pin_changes.conversation_hash
                ORDER BY pin_changes.placed_at, pin_changes.hash
                """)
        }
        var newest: [Data: PinChangeRecord] = [:]
        for line in lines {
            newest[line.conversationHash] = line
        }
        return Array(newest.values)
    }

    /// How many of `actor`'s changes wait for a message not stored yet.
    public func waitingPinChangeCount(fromActor actor: Data) throws -> Int {
        try dbPool.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pin_changes
                WHERE actor = ?
                    AND NOT EXISTS (SELECT 1 FROM messages WHERE messages.message_id = pin_changes.target)
                """, arguments: [actor]) ?? 0
        }
    }

    /// Deletes waiting changes stamped before `timestamp`. Returns how many went.
    public func deleteWaitingPinChanges(olderThan timestamp: Double) throws -> Int {
        try dbPool.write { db in
            try db.execute(sql: """
                DELETE FROM pin_changes
                WHERE timestamp < ?
                    AND NOT EXISTS (SELECT 1 FROM messages WHERE messages.message_id = pin_changes.target)
                """, arguments: [timestamp])
            return db.changesCount
        }
    }

    /// Deletes every change aimed at one message.
    public func deletePinChanges(forTarget target: Data) throws {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM pin_changes WHERE target = ?", arguments: [target])
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

        // FORK ADDITION. Control traffic leaves the conversation alone — see `isSilentMessage`.
        // The row is still ensured, because the message's own foreign key needs it.
        guard !isSilent(message) else {
            try ensureConversationRow(conversationHash, in: db)
            return
        }

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

    /// FORK ADDITION. Whether this message is control traffic: the host recognises its fields and
    /// it says nothing of its own.
    ///
    /// The content check is the fork's own guard rather than the host's business — a control field
    /// is also legal on a message that carries text, and that one is a real message.
    private func isSilent(_ message: LXMessage) -> Bool {
        guard let isSilentMessage, message.content.isEmpty else { return false }
        return isSilentMessage(message.fields)
    }

    /// The empty row a stored message's foreign key needs, for a conversation nothing has been
    /// said in yet. Leaves an existing row untouched.
    private func ensureConversationRow(_ conversationHash: Data, in db: Database) throws {
        guard try ConversationRecord
            .filter(Column("destination_hash") == conversationHash)
            .fetchCount(db) == 0 else { return }
        try ConversationRecord(destinationHash: conversationHash, lastMessageTimestamp: 0).insert(db)
    }
}
