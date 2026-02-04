//
//  LXMessageTests.swift
//  LXMFSwiftTests
//
//  Unit tests for LXMessage packing/unpacking.
//  Tests verify exact match with Python LXMF LXMessage.py behavior.
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMessageTests: XCTestCase {

    // MARK: - Pack Tests

    /// Test packing a simple message
    func testPackSimpleMessage() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Simple test message".data(using: .utf8)!,
            title: "Test Title".data(using: .utf8)!,
            fields: nil,
            desiredMethod: .direct
        )

        let packed = try message.pack()

        // Verify wire format structure
        XCTAssertGreaterThan(packed.count, LXMFConstants.LXMF_OVERHEAD,
                             "Packed message should be > 112 bytes")

        // Verify destination hash at start (16 bytes)
        let destHash = packed.prefix(16)
        XCTAssertEqual(Data(destHash), destIdentity.hash,
                       "Destination hash should be first 16 bytes")

        // Verify source hash is LXMF delivery destination hash
        let sourceHash = packed.dropFirst(16).prefix(16)
        let expectedSourceHash = Destination.hash(identity: sourceIdentity, appName: "lxmf", aspects: ["delivery"])
        XCTAssertEqual(Data(sourceHash), expectedSourceHash,
                       "Source hash should be LXMF delivery destination hash")

        // Verify signature present (64 bytes)
        let signature = packed.dropFirst(32).prefix(64)
        XCTAssertEqual(signature.count, 64, "Signature should be 64 bytes")
    }

    /// Test message state transitions after pack
    func testMessageStates() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )

        // Initial state should be generating
        XCTAssertEqual(message.state, .generating, "Initial state should be generating")

        // After pack, state should be outbound
        _ = try message.pack()
        XCTAssertEqual(message.state, .outbound, "After pack should be outbound")
    }

    /// Test empty message (minimal valid message)
    func testEmptyMessage() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: Data(),  // Empty content
            title: Data(),    // Empty title
            fields: nil,
            desiredMethod: .direct
        )

        let packed = try message.pack()

        // Should still pack successfully
        let minHeaderSize = LXMFConstants.DESTINATION_LENGTH * 2 + LXMFConstants.SIGNATURE_LENGTH
        XCTAssertGreaterThanOrEqual(packed.count, minHeaderSize,
                                    "Empty message should pack with at least header")

        // Unpack and verify
        let unpacked = try LXMessage.unpackFromBytes(packed)
        XCTAssertTrue(unpacked.content.isEmpty, "Content should be empty")
        XCTAssertTrue(unpacked.title.isEmpty, "Title should be empty")
    }

    // MARK: - Unpack Tests

    /// Test round-trip pack/unpack preserves content
    func testRoundtrip() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        let originalContent = "Round-trip test message".data(using: .utf8)!
        let originalTitle = "Round-trip Title".data(using: .utf8)!

        // Pack
        var original = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: originalContent,
            title: originalTitle,
            fields: nil,
            desiredMethod: .direct
        )
        let packed = try original.pack()

        // Unpack
        let unpacked = try LXMessage.unpackFromBytes(packed)

        // Verify content preserved
        XCTAssertEqual(unpacked.content, originalContent, "Content should match")
        XCTAssertEqual(unpacked.title, originalTitle, "Title should match")
        XCTAssertEqual(unpacked.timestamp, original.timestamp, "Timestamp should match")
        XCTAssertEqual(unpacked.hash, original.hash, "Hash should match")
    }

    /// Test unpacked message has incoming=true
    func testUnpackedIsIncoming() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        let packed = try message.pack()

        let unpacked = try LXMessage.unpackFromBytes(packed)
        XCTAssertTrue(unpacked.incoming, "Unpacked message should be incoming")
    }

    // MARK: - Hash Tests

    /// Test that hash excludes stamp
    func testHashExcludesStamp() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        // Use fixed timestamp so both messages have same base data
        let fixedTimestamp = 1704067200.0

        // Create message with stamp
        var messageWithStamp = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        messageWithStamp.timestamp = fixedTimestamp
        messageWithStamp.stamp = Data([1, 2, 3, 4])

        // Create identical message without stamp
        var messageNoStamp = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        messageNoStamp.timestamp = fixedTimestamp

        // Pack both
        _ = try messageWithStamp.pack()
        _ = try messageNoStamp.pack()

        // Hashes should be identical (stamp not included)
        XCTAssertEqual(messageWithStamp.hash, messageNoStamp.hash, "Hash should exclude stamp")
    }

    /// Test hash is 32 bytes
    func testHashLength() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message.pack()

        XCTAssertEqual(message.hash.count, 32, "Hash should be 32 bytes (SHA256)")
    }

    // MARK: - Signature Tests

    /// Test signature is 64 bytes
    func testSignatureLength() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        _ = try message.pack()

        XCTAssertEqual(message.signature.count, 64, "Signature should be 64 bytes (Ed25519)")
    }

    /// Test signature validates with source identity
    func testSignatureValidation() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test message for signature validation".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        let packed = try message.pack()

        // Unpack with source identity for validation
        let unpacked = try LXMessage.unpackFromBytes(packed, sourceIdentity: sourceIdentity)

        XCTAssertTrue(unpacked.signatureValidated, "Signature should validate")
        XCTAssertNil(unpacked.unverifiedReason, "Unverified reason should be nil")
    }

    /// Test invalid signature is detected
    func testInvalidSignatureDetected() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()
        let wrongIdentity = Identity()  // Different identity

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test".data(using: .utf8)!,
            title: Data(),
            fields: nil,
            desiredMethod: .direct
        )
        let packed = try message.pack()

        // Unpack with wrong identity for validation
        let unpacked = try LXMessage.unpackFromBytes(packed, sourceIdentity: wrongIdentity)

        XCTAssertFalse(unpacked.signatureValidated, "Signature should fail validation")
        XCTAssertEqual(unpacked.unverifiedReason, .signatureInvalid, "Should report invalid signature")
    }

    // MARK: - Fields Tests

    /// Test message with fields dictionary
    func testPackWithFields() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        let fields: [UInt8: Any] = [
            0x02: ["lat": 37.7749, "lon": -122.4194],
            0x06: "test_image_data".data(using: .utf8)!
        ]

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Message with fields".data(using: .utf8)!,
            title: Data(),
            fields: fields,
            desiredMethod: .direct
        )

        let packed = try message.pack()

        XCTAssertGreaterThan(packed.count, LXMFConstants.LXMF_OVERHEAD,
                             "Should pack with fields")
    }

    // MARK: - Properties Tests

    /// Test message properties after creation
    func testMessageProperties() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        let message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: "Test content".data(using: .utf8)!,
            title: "Test title".data(using: .utf8)!,
            fields: nil,
            desiredMethod: .opportunistic
        )

        XCTAssertEqual(message.destinationHash, destIdentity.hash)
        XCTAssertEqual(message.method, .opportunistic)
        XCTAssertFalse(message.incoming)
        XCTAssertEqual(message.state, .generating)
        XCTAssertEqual(message.deliveryAttempts, 0)
        XCTAssertNil(message.packed)
    }
}

// MARK: - Data Extension for Tests

extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var i = hexString.startIndex
        for _ in 0..<len {
            let j = hexString.index(i, offsetBy: 2)
            let bytes = hexString[i..<j]
            if var num = UInt8(bytes, radix: 16) {
                data.append(&num, count: 1)
            } else {
                return nil
            }
            i = j
        }
        self = data
    }

    func hexString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}
