//
//  PropagationSyncTests.swift
//  LXMFSwiftTests
//
//  Tests for propagation sync decryption, message parsing, and the
//  full encrypt → decrypt → unpack round-trip that matches the Python
//  LXMF propagation path.
//
//  Reference: Python LXMessage.py lines 434-438, LXMRouter.py lines 2322-2328
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift
import CryptoKit

final class PropagationSyncTests: XCTestCase {

    // MARK: - Encrypt/Decrypt Round-Trip

    /// Test that we can encrypt a packed LXMF message the way Python does for
    /// propagation, then decrypt it the way our sync code does.
    ///
    /// Python flow:
    ///   encrypted = destination.encrypt(packed[DESTINATION_LENGTH:])
    ///   lxmf_data = packed[:DESTINATION_LENGTH] + encrypted
    ///
    /// Swift sync flow:
    ///   decrypted = identity.decrypt(lxmf_data[DESTINATION_LENGTH:], identityHash: identity.hash)
    ///   plaintext_message = lxmf_data[:DESTINATION_LENGTH] + decrypted
    func testPropagatedMessageEncryptDecryptRoundTrip() throws {
        let sourceIdentity = Identity()
        let recipientIdentity = Identity()

        // Create and pack a message to the recipient
        var message = LXMessage(
            destinationHash: Destination.hash(identity: recipientIdentity, appName: "lxmf", aspects: ["delivery"]),
            sourceIdentity: sourceIdentity,
            content: "Hello from propagation!".data(using: .utf8)!,
            title: "Prop Test".data(using: .utf8)!,
            fields: nil,
            desiredMethod: .propagated
        )
        let packed = try message.pack()

        // Simulate what Python LXMessage.py does for propagated messages:
        // encrypted_data = destination.encrypt(packed[DESTINATION_LENGTH:])
        // lxmf_data = packed[:DESTINATION_LENGTH] + encrypted_data
        let destHash = Data(packed.prefix(LXMFConstants.DESTINATION_LENGTH))
        let plaintextPayload = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))

        let encrypted = try Identity.encrypt(
            plaintextPayload,
            to: recipientIdentity.encryptionPublicKey,
            identityHash: recipientIdentity.hash
        )

        // This is what the propagation node stores (minus stamp)
        let propagatedData = destHash + encrypted

        // Verify the encrypted data is NOT the same as plaintext
        XCTAssertNotEqual(propagatedData, packed,
                          "Encrypted propagated data should differ from plaintext packed data")
        XCTAssertGreaterThan(propagatedData.count, packed.count,
                             "Encrypted data should be larger (ephemeral key + IV + HMAC overhead)")

        // Now simulate what our sync code does:
        // decrypt data[DESTINATION_LENGTH:] using our identity
        let receivedDestHash = Data(propagatedData.prefix(LXMFConstants.DESTINATION_LENGTH))
        let receivedEncrypted = Data(propagatedData.dropFirst(LXMFConstants.DESTINATION_LENGTH))

        let decrypted = try recipientIdentity.decrypt(receivedEncrypted, identityHash: recipientIdentity.hash)

        // Reconstruct plaintext message
        let decryptedMessage = receivedDestHash + decrypted

        // Should match the original packed data exactly
        XCTAssertEqual(decryptedMessage, packed,
                       "Decrypted propagated message should match original packed data")

        // Verify we can unpack it
        let unpacked = try LXMessage.unpackFromBytes(decryptedMessage, sourceIdentity: sourceIdentity)
        XCTAssertEqual(String(data: unpacked.content, encoding: .utf8), "Hello from propagation!")
        XCTAssertEqual(String(data: unpacked.title, encoding: .utf8), "Prop Test")
        XCTAssertTrue(unpacked.signatureValidated,
                      "Signature should validate after decrypt")
    }

    /// Test that decrypting with the wrong identity fails.
    func testDecryptWithWrongIdentityFails() throws {
        let sourceIdentity = Identity()
        let recipientIdentity = Identity()
        let wrongIdentity = Identity()

        var message = LXMessage(
            destinationHash: Destination.hash(identity: recipientIdentity, appName: "lxmf", aspects: ["delivery"]),
            sourceIdentity: sourceIdentity,
            content: "Secret message".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        let packed = try message.pack()

        // Encrypt for recipient
        let destHash = Data(packed.prefix(LXMFConstants.DESTINATION_LENGTH))
        let plaintextPayload = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))

        let encrypted = try Identity.encrypt(
            plaintextPayload,
            to: recipientIdentity.encryptionPublicKey,
            identityHash: recipientIdentity.hash
        )
        let propagatedData = destHash + encrypted

        // Try to decrypt with wrong identity - should throw
        let encryptedPayload = Data(propagatedData.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        XCTAssertThrowsError(
            try wrongIdentity.decrypt(encryptedPayload, identityHash: wrongIdentity.hash),
            "Decrypting with wrong identity should fail"
        )
    }

    /// Test that attempting to unpack encrypted data directly (without decryption) fails.
    /// This is the exact bug we fixed: before the fix, lxmfDelivery() tried to unpack
    /// ciphertext as msgpack.
    func testUnpackEncryptedDataFails() throws {
        let sourceIdentity = Identity()
        let recipientIdentity = Identity()

        var message = LXMessage(
            destinationHash: Destination.hash(identity: recipientIdentity, appName: "lxmf", aspects: ["delivery"]),
            sourceIdentity: sourceIdentity,
            content: "This should fail to unpack".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        let packed = try message.pack()

        // Encrypt for recipient (simulating propagation node)
        let destHash = Data(packed.prefix(LXMFConstants.DESTINATION_LENGTH))
        let plaintextPayload = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        let encrypted = try Identity.encrypt(
            plaintextPayload,
            to: recipientIdentity.encryptionPublicKey,
            identityHash: recipientIdentity.hash
        )
        let propagatedData = destHash + encrypted

        // Trying to unpack without decrypting should fail
        XCTAssertThrowsError(
            try LXMessage.unpackFromBytes(propagatedData),
            "Unpacking encrypted propagated data without decryption should fail"
        )
    }

    // MARK: - Message with Fields

    /// Test propagation round-trip with fields (image, file attachments).
    func testPropagatedMessageWithFieldsRoundTrip() throws {
        let sourceIdentity = Identity()
        let recipientIdentity = Identity()

        let imageData = Data(repeating: 0xAB, count: 1024)
        let fields: [UInt8: Any] = [
            0x06: ["png", imageData] as [Any],  // FIELD_IMAGE
        ]

        var message = LXMessage(
            destinationHash: Destination.hash(identity: recipientIdentity, appName: "lxmf", aspects: ["delivery"]),
            sourceIdentity: sourceIdentity,
            content: "Message with image".data(using: .utf8)!,
            title: Data(),
            fields: fields,
            desiredMethod: .propagated
        )
        let packed = try message.pack()

        // Encrypt
        let destHash = Data(packed.prefix(LXMFConstants.DESTINATION_LENGTH))
        let plaintextPayload = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        let encrypted = try Identity.encrypt(
            plaintextPayload,
            to: recipientIdentity.encryptionPublicKey,
            identityHash: recipientIdentity.hash
        )
        let propagatedData = destHash + encrypted

        // Decrypt
        let encryptedPayload = Data(propagatedData.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        let decrypted = try recipientIdentity.decrypt(encryptedPayload, identityHash: recipientIdentity.hash)
        let decryptedMessage = destHash + decrypted

        // Unpack
        let unpacked = try LXMessage.unpackFromBytes(decryptedMessage, sourceIdentity: sourceIdentity)
        XCTAssertEqual(String(data: unpacked.content, encoding: .utf8), "Message with image")
        XCTAssertNotNil(unpacked.fields, "Fields should be preserved")
    }

    /// Test propagated message with large content (would use Resource transfer in real sync).
    func testPropagatedLargeMessageRoundTrip() throws {
        let sourceIdentity = Identity()
        let recipientIdentity = Identity()

        // 40KB content (similar to what was seen in live sync)
        let largeContent = Data(repeating: 0x42, count: 40_000)

        var message = LXMessage(
            destinationHash: Destination.hash(identity: recipientIdentity, appName: "lxmf", aspects: ["delivery"]),
            sourceIdentity: sourceIdentity,
            content: largeContent,
            title: "Large".data(using: .utf8)!,
            fields: nil,
            desiredMethod: .propagated
        )
        let packed = try message.pack()

        // Encrypt
        let destHash = Data(packed.prefix(LXMFConstants.DESTINATION_LENGTH))
        let plaintextPayload = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        let encrypted = try Identity.encrypt(
            plaintextPayload,
            to: recipientIdentity.encryptionPublicKey,
            identityHash: recipientIdentity.hash
        )
        let propagatedData = destHash + encrypted

        // Decrypt
        let encryptedPayload = Data(propagatedData.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        let decrypted = try recipientIdentity.decrypt(encryptedPayload, identityHash: recipientIdentity.hash)
        let decryptedMessage = destHash + decrypted

        XCTAssertEqual(decryptedMessage, packed)

        let unpacked = try LXMessage.unpackFromBytes(decryptedMessage, sourceIdentity: sourceIdentity)
        XCTAssertEqual(unpacked.content, largeContent)
    }

    // MARK: - Transient ID Tests

    /// Test that transient ID is computed from encrypted data (not plaintext).
    /// Python: transient_id = RNS.Identity.full_hash(dest_hash + encrypted_data)
    func testTransientIdComputedFromEncryptedData() throws {
        let sourceIdentity = Identity()
        let recipientIdentity = Identity()

        var message = LXMessage(
            destinationHash: Destination.hash(identity: recipientIdentity, appName: "lxmf", aspects: ["delivery"]),
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        let packed = try message.pack()

        let destHash = Data(packed.prefix(LXMFConstants.DESTINATION_LENGTH))
        let plaintextPayload = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        let encrypted = try Identity.encrypt(
            plaintextPayload,
            to: recipientIdentity.encryptionPublicKey,
            identityHash: recipientIdentity.hash
        )
        let propagatedData = destHash + encrypted

        // Transient ID = SHA256(propagated_data) — computed from encrypted form
        let transientId = Hashing.fullHash(propagatedData)
        XCTAssertEqual(transientId.count, 32, "Transient ID should be 32 bytes")

        // Transient ID from plaintext should be different
        let plaintextTransientId = Hashing.fullHash(packed)
        XCTAssertNotEqual(transientId, plaintextTransientId,
                          "Transient ID from encrypted data should differ from plaintext")
    }

    // MARK: - LXMessage Timestamp Parsing

    /// Test that timestamps packed as different msgpack types all unpack correctly.
    /// Python packs timestamps as float64, but msgpack can encode them as various types.
    func testTimestampParsingVariousTypes() throws {
        let sourceIdentity = Identity()
        let destHash = Destination.hash(identity: sourceIdentity, appName: "lxmf", aspects: ["delivery"])
        let sourceHash = destHash  // Using same for simplicity
        let signature = Data(repeating: 0x00, count: 64)

        // Test with double timestamp (standard Python behavior)
        let doublePayload = packLXMF(.array([
            .double(1707264000.123),
            .binary(Data()),  // title
            .binary("test".data(using: .utf8)!),  // content
            .null  // fields
        ]))
        let doubleMsg = destHash + sourceHash + signature + doublePayload
        let unpacked1 = try LXMessage.unpackFromBytes(doubleMsg)
        XCTAssertEqual(unpacked1.timestamp, 1707264000.123, accuracy: 0.001)

        // Test with uint timestamp
        let uintPayload = packLXMF(.array([
            .uint(1707264000),
            .binary(Data()),
            .binary("test".data(using: .utf8)!),
            .null
        ]))
        let uintMsg = destHash + sourceHash + signature + uintPayload
        let unpacked2 = try LXMessage.unpackFromBytes(uintMsg)
        XCTAssertEqual(unpacked2.timestamp, 1707264000.0, accuracy: 0.001)

        // Test with int timestamp
        let intPayload = packLXMF(.array([
            .int(1707264000),
            .binary(Data()),
            .binary("test".data(using: .utf8)!),
            .null
        ]))
        let intMsg = destHash + sourceHash + signature + intPayload
        let unpacked3 = try LXMessage.unpackFromBytes(intMsg)
        XCTAssertEqual(unpacked3.timestamp, 1707264000.0, accuracy: 0.001)
    }

    /// Test that title/content packed as string (not binary) still unpack.
    func testStringTitleAndContentParsing() throws {
        let sourceIdentity = Identity()
        let destHash = Destination.hash(identity: sourceIdentity, appName: "lxmf", aspects: ["delivery"])
        let sourceHash = destHash
        let signature = Data(repeating: 0x00, count: 64)

        let payload = packLXMF(.array([
            .double(1707264000.0),
            .string("String Title"),   // title as string instead of binary
            .string("String Content"), // content as string instead of binary
            .null
        ]))
        let msgData = destHash + sourceHash + signature + payload
        let unpacked = try LXMessage.unpackFromBytes(msgData)

        XCTAssertEqual(String(data: unpacked.title, encoding: .utf8), "String Title")
        XCTAssertEqual(String(data: unpacked.content, encoding: .utf8), "String Content")
    }

    // MARK: - Sync ACK Transient ID Correctness

    /// Test that using LIST transient IDs for ACK is correct even when
    /// the message data has been modified (stamp stripped).
    func testAckUsesListTransientIds() throws {
        // Simulate: server has messages with stamps
        let messageWithStamp = Data(repeating: 0xAA, count: 200) + Data(repeating: 0xBB, count: 32)  // stamp at end
        let serverTransientId = Hashing.fullHash(messageWithStamp)

        // Server strips stamp before sending
        let messageWithoutStamp = Data(repeating: 0xAA, count: 200)
        let clientRecomputedId = Hashing.fullHash(messageWithoutStamp)

        // These should NOT match — proving we can't recompute server's IDs
        XCTAssertNotEqual(serverTransientId, clientRecomputedId,
                          "Recomputed ID from stamp-stripped data should differ from server's ID")

        // Therefore, ACK must use the original IDs from the LIST response
    }

    // MARK: - Identity Encrypt/Decrypt

    /// Test basic Identity encrypt/decrypt round-trip (foundation of propagation).
    func testIdentityEncryptDecryptRoundTrip() throws {
        let identity = Identity()
        let plaintext = "Hello, Reticulum!".data(using: .utf8)!

        let encrypted = try Identity.encrypt(
            plaintext,
            to: identity.encryptionPublicKey,
            identityHash: identity.hash
        )

        let decrypted = try identity.decrypt(encrypted, identityHash: identity.hash)
        XCTAssertEqual(decrypted, plaintext)
    }

    /// Test that each encryption produces different ciphertext (ephemeral key).
    func testEncryptionProducesDifferentCiphertext() throws {
        let identity = Identity()
        let plaintext = "Same message".data(using: .utf8)!

        let encrypted1 = try Identity.encrypt(
            plaintext, to: identity.encryptionPublicKey, identityHash: identity.hash
        )
        let encrypted2 = try Identity.encrypt(
            plaintext, to: identity.encryptionPublicKey, identityHash: identity.hash
        )

        XCTAssertNotEqual(encrypted1, encrypted2,
                          "Each encryption should use a different ephemeral key")

        // But both should decrypt to the same plaintext
        let decrypted1 = try identity.decrypt(encrypted1, identityHash: identity.hash)
        let decrypted2 = try identity.decrypt(encrypted2, identityHash: identity.hash)
        XCTAssertEqual(decrypted1, plaintext)
        XCTAssertEqual(decrypted2, plaintext)
    }

    /// Test encryption overhead matches expected format.
    /// Format: [ephemeral_pub 32B][IV 16B][ciphertext][HMAC 32B]
    func testEncryptionOverhead() throws {
        let identity = Identity()
        let plaintext = Data(repeating: 0x42, count: 100)

        let encrypted = try Identity.encrypt(
            plaintext, to: identity.encryptionPublicKey, identityHash: identity.hash
        )

        // Overhead = 32 (ephemeral pub) + 16 (IV) + 32 (HMAC) + padding = 80 + padding
        // AES-CBC pads to 16-byte blocks, so 100 bytes -> 112 bytes ciphertext
        // Total: 32 + 16 + 112 + 32 = 192
        let overhead = encrypted.count - plaintext.count
        XCTAssertGreaterThanOrEqual(overhead, 80,
                                     "Encryption overhead should be >= 80 bytes (key + IV + HMAC)")
        XCTAssertLessThanOrEqual(overhead, 96,
                                  "Encryption overhead should be <= 96 bytes (with padding)")
    }

    // MARK: - Edge Cases

    /// Test empty content message through propagation path.
    func testPropagatedEmptyContentMessage() throws {
        let sourceIdentity = Identity()
        let recipientIdentity = Identity()

        var message = LXMessage(
            destinationHash: Destination.hash(identity: recipientIdentity, appName: "lxmf", aspects: ["delivery"]),
            sourceIdentity: sourceIdentity,
            content: Data(),
            title: Data(),
            fields: nil,
            desiredMethod: .propagated
        )
        let packed = try message.pack()

        let destHash = Data(packed.prefix(LXMFConstants.DESTINATION_LENGTH))
        let plaintextPayload = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        let encrypted = try Identity.encrypt(
            plaintextPayload,
            to: recipientIdentity.encryptionPublicKey,
            identityHash: recipientIdentity.hash
        )
        let propagatedData = destHash + encrypted

        // Decrypt and unpack
        let encryptedPayload = Data(propagatedData.dropFirst(LXMFConstants.DESTINATION_LENGTH))
        let decrypted = try recipientIdentity.decrypt(encryptedPayload, identityHash: recipientIdentity.hash)
        let decryptedMessage = destHash + decrypted

        let unpacked = try LXMessage.unpackFromBytes(decryptedMessage, sourceIdentity: sourceIdentity)
        XCTAssertTrue(unpacked.content.isEmpty)
        XCTAssertTrue(unpacked.signatureValidated)
    }

    /// Test that data shorter than DESTINATION_LENGTH is handled gracefully.
    func testTooShortDataDoesNotCrash() throws {
        let shortData = Data(repeating: 0xFF, count: 10)

        // Should throw, not crash
        XCTAssertThrowsError(try LXMessage.unpackFromBytes(shortData))
    }

    /// Test multiple messages encrypted for the same recipient have different ciphertext.
    func testMultipleMessagesProduceDifferentCiphertext() throws {
        let sourceIdentity = Identity()
        let recipientIdentity = Identity()

        var propagatedDatas: [Data] = []

        for i in 0..<3 {
            var message = LXMessage(
                destinationHash: Destination.hash(identity: recipientIdentity, appName: "lxmf", aspects: ["delivery"]),
                sourceIdentity: sourceIdentity,
                content: "Message \(i)".data(using: .utf8)!,
                title: Data(),
                fields: nil,
                desiredMethod: .propagated
            )
            let packed = try message.pack()
            let destHash = Data(packed.prefix(LXMFConstants.DESTINATION_LENGTH))
            let plaintextPayload = Data(packed.dropFirst(LXMFConstants.DESTINATION_LENGTH))
            let encrypted = try Identity.encrypt(
                plaintextPayload,
                to: recipientIdentity.encryptionPublicKey,
                identityHash: recipientIdentity.hash
            )
            propagatedDatas.append(destHash + encrypted)
        }

        // All encrypted forms should be different
        XCTAssertNotEqual(propagatedDatas[0], propagatedDatas[1])
        XCTAssertNotEqual(propagatedDatas[1], propagatedDatas[2])

        // But all should decrypt and unpack successfully
        for (i, propagatedData) in propagatedDatas.enumerated() {
            let encryptedPayload = Data(propagatedData.dropFirst(LXMFConstants.DESTINATION_LENGTH))
            let decrypted = try recipientIdentity.decrypt(encryptedPayload, identityHash: recipientIdentity.hash)
            let decryptedMessage = Data(propagatedData.prefix(LXMFConstants.DESTINATION_LENGTH)) + decrypted
            let unpacked = try LXMessage.unpackFromBytes(decryptedMessage, sourceIdentity: sourceIdentity)
            XCTAssertEqual(String(data: unpacked.content, encoding: .utf8), "Message \(i)")
        }
    }
}
