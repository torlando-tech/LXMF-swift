//
//  MessageRecord.swift
//  LXMFSwift
//
//  GRDB record for persisting LXMF messages to SQLite.
//  Stores all LXMessage fields including packed wire format for retransmission.
//

import Foundation
import GRDB

/// Database record for LXMF messages.
///
/// Persists all fields from LXMessage including the packed wire format.
/// Supports conversion to/from LXMessage for storage and retrieval.
public struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "messages"

    // MARK: - Database Columns

    /// Message ID (hash, 32 bytes)
    public var messageId: Data

    /// Conversation destination hash (16 bytes)
    public var conversationHash: Data

    /// Message destination hash (16 bytes)
    public var destinationHash: Data

    /// Message source hash (16 bytes)
    public var sourceHash: Data

    /// Ed25519 signature (64 bytes)
    public var signature: Data

    /// Message timestamp (Unix time)
    public var timestamp: Double

    /// Message title (can be empty)
    public var title: Data

    /// Message content
    public var content: Data

    /// Fields dictionary (MessagePack encoded, optional)
    public var fields: Data?

    /// Proof-of-work stamp (optional)
    public var stamp: Data?

    /// Message state (UInt8 raw value)
    public var state: UInt8

    /// Delivery method (UInt8 raw value)
    public var method: UInt8

    /// Number of delivery attempts
    public var deliveryAttempts: Int

    /// Send/receive progress (0.0 to 1.0)
    public var progress: Double

    /// True if incoming message, false if outbound
    public var incoming: Bool

    /// RSSI (signal strength, optional)
    public var rssi: Double?

    /// SNR (signal-to-noise ratio, optional)
    public var snr: Double?

    /// Link quality (optional)
    public var q: Double?

    /// Ratchet ID (optional)
    public var ratchetId: Data?

    /// Packed LXMF wire format (for retransmission)
    public var packedLxmf: Data

    /// Record creation timestamp
    public var createdAt: Double

    /// Record update timestamp
    public var updatedAt: Double

    // MARK: - Column Mapping (snake_case to camelCase)

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case conversationHash = "conversation_hash"
        case destinationHash = "destination_hash"
        case sourceHash = "source_hash"
        case signature
        case timestamp
        case title
        case content
        case fields
        case stamp
        case state
        case method
        case deliveryAttempts = "delivery_attempts"
        case progress
        case incoming
        case rssi
        case snr
        case q
        case ratchetId = "ratchet_id"
        case packedLxmf = "packed_lxmf"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    // MARK: - Initialization

    /// Create record from LXMessage.
    ///
    /// - Parameter message: LXMessage to persist
    /// - Throws: LXMFError if message not packed or missing required fields
    public init(from message: LXMessage) throws {
        guard let packed = message.packed else {
            throw LXMFError.invalidMessageFormat("Message must be packed before persisting")
        }

        self.messageId = message.hash
        self.destinationHash = message.destinationHash
        self.sourceHash = message.sourceHash
        self.signature = message.signature
        self.timestamp = message.timestamp
        self.title = message.title
        self.content = message.content
        self.stamp = message.stamp
        self.state = message.state.rawValue
        self.method = message.method.rawValue
        self.incoming = message.incoming
        self.packedLxmf = packed

        // Conversation hash is destination for incoming, source for outbound
        self.conversationHash = message.incoming ? message.sourceHash : message.destinationHash

        // Fields are already stored in packedLxmf wire format.
        // We restore the complete message from packedLxmf in toLXMessage(),
        // so we don't need to separately serialize the fields dictionary.
        // This column is retained for potential future use in database queries.
        self.fields = nil

        self.deliveryAttempts = 0
        self.progress = 0.0
        self.rssi = nil
        self.snr = nil
        self.q = nil
        self.ratchetId = nil

        let now = Date().timeIntervalSince1970
        self.createdAt = now
        self.updatedAt = now
    }

    // MARK: - Conversion

    /// Convert record back to LXMessage.
    ///
    /// - Returns: LXMessage reconstructed from record
    /// - Throws: LXMFError if unpacking fails
    public func toLXMessage() throws -> LXMessage {
        // Unpack from stored wire format
        var message = try LXMessage.unpackFromBytes(packedLxmf)

        // Restore state (may have changed from original)
        guard let restoredState = LXMessageState(rawValue: state) else {
            throw LXMFError.invalidMessageFormat("Invalid state value: \(state)")
        }
        message.state = restoredState

        // Restore method
        guard let restoredMethod = LXDeliveryMethod(rawValue: method) else {
            throw LXMFError.invalidMessageFormat("Invalid method value: \(method)")
        }
        message.method = restoredMethod

        return message
    }
}
