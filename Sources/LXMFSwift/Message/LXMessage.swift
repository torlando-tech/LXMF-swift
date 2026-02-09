//
//  LXMessage.swift
//  LXMFSwift
//
//  LXMF message structure with MessagePack encoding/decoding.
//  Wire format matches Python LXMF exactly for interoperability.
//
//  Reference: LXMF/LXMessage.py lines 360-466 (pack), 734-805 (unpack)
//

import Foundation
import CryptoKit
import ReticulumSwift

/// LXMF message structure.
///
/// Wire format: [destination_hash: 16][source_hash: 16][signature: 64][msgpack_payload]
/// where payload = [timestamp, title, content, fields, stamp?]
///
/// Hash computation (CRITICAL):
/// - hash = SHA256(destination_hash + source_hash + msgpack([timestamp, title, content, fields]))
/// - stamp is NOT included in hash computation
/// - signature = sign(destination_hash + source_hash + msgpack(payload) + hash)
public struct LXMessage {
    // MARK: - LXMF Field Keys

    public static let FIELD_ICON_APPEARANCE: UInt8 = 0x04
    public static let FIELD_FILE_ATTACHMENTS: UInt8 = 0x05
    public static let FIELD_IMAGE: UInt8 = 0x06
    public static let FIELD_AUDIO: UInt8 = 0x07

    // MARK: - Properties

    /// Destination hash (16 bytes, truncated SHA256)
    public let destinationHash: Data

    /// Source hash (16 bytes, truncated SHA256)
    public let sourceHash: Data

    /// Ed25519 signature (64 bytes)
    public var signature: Data

    /// Message timestamp (Unix time as Double)
    public var timestamp: Double

    /// Message title (can be empty, stored as bytes for encoding)
    public var title: Data

    /// Message content (stored as bytes for encoding)
    public var content: Data

    /// Fields dictionary (optional metadata, keys are UInt8)
    public var fields: [UInt8: Any]?

    /// Proof-of-work stamp (optional, not included in hash)
    public var stamp: Data?

    /// Message hash (32 bytes SHA256, computed during pack)
    public var hash: Data

    /// Message state
    public var state: LXMessageState

    /// Delivery method
    public var method: LXDeliveryMethod

    /// Message representation (packet or resource)
    public var representation: LXMessageRepresentation

    /// True for received messages, false for outbound
    public var incoming: Bool

    /// Cached wire format (populated after pack())
    public var packed: Data?

    /// Whether signature has been validated
    public var signatureValidated: Bool

    /// Reason signature is unverified (if signatureValidated == false)
    public var unverifiedReason: LXUnverifiedReason?

    /// Source identity (for outbound messages, can sign)
    private var sourceIdentity: Identity?

    /// Number of delivery attempts (for outbound messages)
    public var deliveryAttempts: Int = 0

    /// Next scheduled delivery attempt (for retry logic)
    public var nextDeliveryAttempt: Date?

    /// Delivery progress (0.0 to 1.0)
    public var progress: Double = 0.0

    /// Fallback method when opportunistic can't be used (message too large).
    /// Set by the app layer to control large-message behavior:
    /// - .direct: try link-based delivery, then propagation on failure
    /// - .propagated: skip direct, go straight to propagation node
    public var fallbackMethod: LXDeliveryMethod?

    /// Physical layer statistics (for received messages)
    public var rssi: Double?
    public var snr: Double?
    public var q: Double?

    // MARK: - Initialization

    /// Create new outbound message.
    ///
    /// - Parameters:
    ///   - destinationHash: 16-byte destination hash
    ///   - sourceIdentity: Identity for signing
    ///   - content: Message content (bytes)
    ///   - title: Message title (bytes, can be empty)
    ///   - fields: Optional metadata dictionary
    ///   - desiredMethod: Delivery method
    public init(
        destinationHash: Data,
        sourceIdentity: Identity,
        content: Data,
        title: Data,
        fields: [UInt8: Any]?,
        desiredMethod: LXDeliveryMethod
    ) {
        self.destinationHash = destinationHash
        // sourceHash must be the LXMF delivery Destination hash, not raw Identity hash
        // Python LXMF: self.source_hash = source.hash (where source is a Destination)
        self.sourceHash = Destination.hash(identity: sourceIdentity, appName: "lxmf", aspects: ["delivery"])
        self.sourceIdentity = sourceIdentity
        self.content = content
        self.title = title
        self.fields = fields
        self.method = desiredMethod
        self.representation = .unknown
        self.state = .generating
        self.incoming = false
        self.timestamp = 0  // Will be set on pack
        self.signature = Data()
        self.hash = Data()
        self.signatureValidated = false
    }

    // MARK: - Packing

    /// Pack message to wire format.
    ///
    /// Process:
    /// 1. Set timestamp if not already set
    /// 2. Create payload array: [timestamp, title, content, fields]
    /// 3. Compute hash: SHA256(destinationHash + sourceHash + msgpack(payload))
    /// 4. Create signedPart: destinationHash + sourceHash + msgpack(payload) + hash
    /// 5. Sign with source identity
    /// 6. If stamp present, append to payload: [timestamp, title, content, fields, stamp]
    /// 7. Assemble packed: destinationHash + sourceHash + signature + msgpack(payload)
    ///
    /// - Returns: Wire format bytes
    /// - Throws: LXMFError if packing fails
    public mutating func pack() throws -> Data {
        guard let identity = sourceIdentity else {
            throw LXMFError.noSourceIdentity
        }

        // Set timestamp if not set
        if timestamp == 0 {
            timestamp = Date().timeIntervalSince1970
        }

        // Create payload array WITHOUT stamp (for hash computation)
        var payloadArray: [LXMFMessagePackValue] = [
            .double(timestamp),
            .binary(title),
            .binary(content),
            .null  // Placeholder for fields
        ]

        // Encode fields if present
        if let fields = fields {
            // Convert [UInt8: Any] to LXMFMessagePackValue map
            var fieldsMap: [LXMFMessagePackValue: LXMFMessagePackValue] = [:]
            for (key, value) in fields {
                let keyValue = LXMFMessagePackValue.uint(UInt64(key))
                // Convert value to LXMFMessagePackValue
                if let dataValue = value as? Data {
                    fieldsMap[keyValue] = .binary(dataValue)
                } else if let stringValue = value as? String {
                    fieldsMap[keyValue] = .string(stringValue)
                } else if let intValue = value as? Int {
                    fieldsMap[keyValue] = .int(Int64(intValue))
                } else if let arrayValue = value as? [Any] {
                    // Convert array to MessagePack with recursive nested array support
                    // Handles flat arrays (Field 4 icon appearance) and nested arrays
                    // (Field 5 file attachments: [[filename, data], ...])
                    fieldsMap[keyValue] = .array(Self.convertArrayToMsgpack(arrayValue))
                } else if let dictValue = value as? [String: Any] {
                    // Convert nested dict to MessagePack
                    var nestedMap: [LXMFMessagePackValue: LXMFMessagePackValue] = [:]
                    for (k, v) in dictValue {
                        let nestedKey = LXMFMessagePackValue.string(k)
                        if let doubleVal = v as? Double {
                            nestedMap[nestedKey] = .double(doubleVal)
                        } else if let intVal = v as? Int {
                            nestedMap[nestedKey] = .int(Int64(intVal))
                        } else if let strVal = v as? String {
                            nestedMap[nestedKey] = .string(strVal)
                        }
                    }
                    fieldsMap[keyValue] = .map(nestedMap)
                }
            }
            payloadArray[3] = .map(fieldsMap)
        }

        // Encode payload WITHOUT stamp (for hash)
        let payloadForHash = LXMFMessagePackValue.array(payloadArray)
        let packedPayloadForHash = packLXMF(payloadForHash)

        // Compute hash
        var hashedPart = Data()
        hashedPart.append(destinationHash)
        hashedPart.append(sourceHash)
        hashedPart.append(packedPayloadForHash)
        self.hash = Data(SHA256.hash(data: hashedPart))

        // Create signed part
        var signedPart = Data()
        signedPart.append(hashedPart)
        signedPart.append(self.hash)

        // Sign
        self.signature = try identity.sign(signedPart)
        self.signatureValidated = true

        // Now add stamp to payload if present
        if let stamp = stamp {
            payloadArray.append(.binary(stamp))
        }

        // Pack final payload (with stamp if present)
        let finalPayload = LXMFMessagePackValue.array(payloadArray)
        let packedFinalPayload = packLXMF(finalPayload)

        // Assemble wire format
        var packed = Data()
        packed.append(destinationHash)
        packed.append(sourceHash)
        packed.append(signature)
        packed.append(packedFinalPayload)

        self.packed = packed
        self.state = .outbound

        return packed
    }

    // MARK: - Unpacking

    /// Unpack message from wire format bytes.
    ///
    /// Process:
    /// 1. Extract destinationHash (bytes 0-16)
    /// 2. Extract sourceHash (bytes 16-32)
    /// 3. Extract signature (bytes 32-96)
    /// 4. Unpack remainder as msgpack array
    /// 5. Extract timestamp, title, content, fields from array
    /// 6. If array has 5 elements, 5th is stamp
    /// 7. Compute hash (without stamp in payload)
    /// 8. Optionally validate signature if sourceIdentity provided
    /// 9. Return LXMessage with incoming=true
    ///
    /// - Parameters:
    ///   - data: Wire format bytes
    ///   - sourceIdentity: Optional source identity for signature validation
    /// - Returns: Unpacked LXMessage
    /// - Throws: LXMFError if unpacking fails
    public static func unpackFromBytes(_ data: Data, sourceIdentity: Identity? = nil) throws -> LXMessage {
        // Minimum size: dest_hash(16) + src_hash(16) + signature(64) + minimal msgpack payload(~15)
        // LXMF_OVERHEAD (112) is for typical messages; empty messages can be slightly smaller (~111 bytes)
        let minHeaderSize = 2 * LXMFConstants.DESTINATION_LENGTH + LXMFConstants.SIGNATURE_LENGTH
        guard data.count > minHeaderSize else {  // Must have at least header + some payload
            throw LXMFError.invalidMessageFormat("Message too short")
        }

        // Extract header components
        let destinationHash = data.prefix(LXMFConstants.DESTINATION_LENGTH)
        let sourceHash = data.dropFirst(LXMFConstants.DESTINATION_LENGTH).prefix(LXMFConstants.DESTINATION_LENGTH)
        let signature = data.dropFirst(2 * LXMFConstants.DESTINATION_LENGTH).prefix(LXMFConstants.SIGNATURE_LENGTH)
        let packedPayload = data.dropFirst(2 * LXMFConstants.DESTINATION_LENGTH + LXMFConstants.SIGNATURE_LENGTH)

        // Unpack payload - convert to contiguous Data to avoid slice issues
        let contiguousPayload = Data(packedPayload)
        guard let payloadValue = try? unpackLXMF(contiguousPayload),
              case .array(var payloadArray) = payloadValue else {
            throw LXMFError.invalidMessageFormat("Could not unpack payload")
        }

        // Extract stamp if present (5th element)
        var stamp: Data? = nil
        if payloadArray.count > 4 {
            if case .binary(let stampData) = payloadArray[4] {
                stamp = stampData
            }
            // Remove stamp from array for hash computation
            payloadArray = Array(payloadArray.prefix(4))
        }

        // Extract fields
        guard payloadArray.count >= 4 else {
            throw LXMFError.invalidMessageFormat("Payload array too short")
        }

        guard case .double(let timestamp) = payloadArray[0] else {
            throw LXMFError.invalidMessageFormat("Invalid timestamp")
        }

        guard case .binary(let title) = payloadArray[1] else {
            throw LXMFError.invalidMessageFormat("Invalid title")
        }

        guard case .binary(let content) = payloadArray[2] else {
            throw LXMFError.invalidMessageFormat("Invalid content")
        }

        // Fields can be nil or map
        var fields: [UInt8: Any]? = nil
        if case .map(let fieldsMap) = payloadArray[3] {
            var extractedFields: [UInt8: Any] = [:]
            for (key, value) in fieldsMap {
                if case .uint(let keyInt) = key {
                    let keyByte = UInt8(keyInt)
                    // Extract value
                    switch value {
                    case .binary(let data):
                        extractedFields[keyByte] = data
                    case .string(let str):
                        extractedFields[keyByte] = str
                    case .int(let int):
                        extractedFields[keyByte] = int
                    case .array(let arr):
                        // Convert msgpack array to [Any] with recursive nested array support
                        // Handles flat arrays (Field 4 icon appearance) and nested arrays
                        // (Field 5 file attachments: [[filename, data], ...])
                        extractedFields[keyByte] = Self.convertMsgpackArrayToSwift(arr)
                    case .map(let nestedMap):
                        // Convert nested map to [String: Any]
                        var nestedDict: [String: Any] = [:]
                        for (nk, nv) in nestedMap {
                            if case .string(let nkStr) = nk {
                                switch nv {
                                case .double(let dbl):
                                    nestedDict[nkStr] = dbl
                                case .int(let int):
                                    nestedDict[nkStr] = int
                                case .string(let str):
                                    nestedDict[nkStr] = str
                                default:
                                    break
                                }
                            }
                        }
                        extractedFields[keyByte] = nestedDict
                    default:
                        break
                    }
                }
            }
            fields = extractedFields
        }

        // Recompute hash (without stamp)
        let payloadForHash = LXMFMessagePackValue.array(payloadArray)
        let packedPayloadForHash = packLXMF(payloadForHash)

        var hashedPart = Data()
        hashedPart.append(destinationHash)
        hashedPart.append(sourceHash)
        hashedPart.append(packedPayloadForHash)
        let computedHash = Data(SHA256.hash(data: hashedPart))

        // Validate signature if source identity provided
        var signatureValidated = false
        var unverifiedReason: LXUnverifiedReason? = nil

        if let sourceIdentity = sourceIdentity {
            var signedPart = Data()
            signedPart.append(hashedPart)
            signedPart.append(computedHash)

            let isValid = sourceIdentity.verify(signature: signature, for: signedPart)
            signatureValidated = isValid
            if !isValid {
                unverifiedReason = .signatureInvalid
            }
        } else {
            unverifiedReason = .sourceUnknown
        }

        // Create message
        var message = LXMessage(
            destinationHash: Data(destinationHash),
            sourceHash: Data(sourceHash),
            signature: Data(signature),
            timestamp: timestamp,
            title: title,
            content: content,
            fields: fields,
            hash: computedHash,
            stamp: stamp,
            incoming: true,
            packed: data,
            signatureValidated: signatureValidated,
            unverifiedReason: unverifiedReason
        )

        return message
    }

    /// Internal initializer for unpacked messages.
    private init(
        destinationHash: Data,
        sourceHash: Data,
        signature: Data,
        timestamp: Double,
        title: Data,
        content: Data,
        fields: [UInt8: Any]?,
        hash: Data,
        stamp: Data?,
        incoming: Bool,
        packed: Data,
        signatureValidated: Bool,
        unverifiedReason: LXUnverifiedReason?
    ) {
        self.destinationHash = destinationHash
        self.sourceHash = sourceHash
        self.signature = signature
        self.timestamp = timestamp
        self.title = title
        self.content = content
        self.fields = fields
        self.hash = hash
        self.stamp = stamp
        self.incoming = incoming
        self.packed = packed
        self.signatureValidated = signatureValidated
        self.unverifiedReason = unverifiedReason
        self.state = .delivered  // Incoming messages are delivered
        self.method = .direct  // Default
        self.representation = .unknown
        self.sourceIdentity = nil
    }

    /// Create outbound message for UI usage without Identity.
    ///
    /// This initializer is for app-side message creation where the actual signing
    /// is handled by the Network Extension. The message will be saved to the shared
    /// database with `.outbound` state, and the extension will process it.
    ///
    /// - Parameters:
    ///   - destinationHash: 16-byte destination hash
    ///   - sourceHash: 16-byte local identity hash
    ///   - content: Message content (bytes)
    ///   - title: Message title (bytes, can be empty)
    ///   - timestamp: Unix timestamp
    ///   - state: Initial message state (typically .outbound)
    ///   - incoming: Whether this is an incoming message
    public init(
        destinationHash: Data,
        sourceHash: Data,
        content: Data,
        title: Data,
        timestamp: Double,
        state: LXMessageState,
        incoming: Bool
    ) {
        self.destinationHash = destinationHash
        self.sourceHash = sourceHash
        self.content = content
        self.title = title
        self.timestamp = timestamp
        self.state = state
        self.incoming = incoming
        self.signature = Data()
        self.hash = Data()
        self.fields = nil
        self.stamp = nil
        self.method = .direct
        self.representation = .unknown
        self.signatureValidated = false
        self.unverifiedReason = nil
        self.sourceIdentity = nil
        self.packed = nil
    }

    // MARK: - Array Conversion Helpers

    /// Convert a Swift `[Any]` array to MessagePack values, handling nested arrays recursively.
    private static func convertArrayToMsgpack(_ array: [Any]) -> [LXMFMessagePackValue] {
        var result: [LXMFMessagePackValue] = []
        for item in array {
            if let s = item as? String { result.append(.string(s)) }
            else if let d = item as? Data { result.append(.binary(d)) }
            else if let i = item as? Int { result.append(.int(Int64(i))) }
            else if let nested = item as? [Any] {
                result.append(.array(convertArrayToMsgpack(nested)))
            }
        }
        return result
    }

    /// Convert a MessagePack array to Swift `[Any]`, handling nested arrays recursively.
    private static func convertMsgpackArrayToSwift(_ array: [LXMFMessagePackValue]) -> [Any] {
        var result: [Any] = []
        for item in array {
            switch item {
            case .string(let s): result.append(s)
            case .binary(let d): result.append(d)
            case .int(let i): result.append(i)
            case .uint(let u): result.append(u)
            case .array(let nested):
                result.append(convertMsgpackArrayToSwift(nested))
            default: break
            }
        }
        return result
    }
}
