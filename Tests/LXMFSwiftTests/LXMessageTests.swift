// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

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

// MARK: - Image Message Crash Reproduction Tests

final class LXMessageImageCrashTests: XCTestCase {

    /// Test: pack and unpack a message with a 77KB JPEG image field
    /// This reproduces the crash loop that occurred when pending outbound
    /// image messages were loaded from the database on startup.
    func testLargeImageMessagePackUnpack() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        // Create ~77KB of fake JPEG data (JPEG header + random)
        var jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])  // JPEG SOI + APP0 marker
        jpegData.append(Data(repeating: 0xAB, count: 77400))

        // Build fields with image + icon appearance (matching real message)
        let fields: [UInt8: Any] = [
            LXMessage.FIELD_IMAGE: ["jpeg", jpegData] as [Any],
            0x04: ["food-apple", Data([0xFF, 0xFF, 0xFF]), Data([0x1E, 0x88, 0xE5])] as [Any]
        ]

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: Data(),  // image-only, no text
            title: Data(),
            fields: fields,
            desiredMethod: .direct
        )

        // Step 1: Pack (should produce ~77.5KB)
        let packed = try message.pack()
        XCTAssertGreaterThan(packed.count, 77000, "Packed message should be >77KB")
        print("[TEST] Packed size: \(packed.count) bytes")

        // Step 2: Unpack (simulates loadPendingOutbound → toLXMessage)
        let unpacked = try LXMessage.unpackFromBytes(packed)
        XCTAssertNotNil(unpacked.fields)

        // Step 3: Verify image field survived round-trip
        let imageField = unpacked.fields?[LXMessage.FIELD_IMAGE] as? [Any]
        XCTAssertNotNil(imageField, "Image field should be present after unpack")
        XCTAssertEqual(imageField?.count, 2, "Image field should have [format, data]")

        let format = imageField?[0] as? String
        XCTAssertEqual(format, "jpeg")

        let data = imageField?[1] as? Data
        XCTAssertEqual(data?.count, 77404, "Image data should be 77404 bytes")
    }

    /// Test: create MessageRecord from packed image message and convert back
    /// This exercises the DB persist/restore path
    func testImageMessageRecordRoundTrip() throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpegData.append(Data(repeating: 0xCD, count: 77400))

        let fields: [UInt8: Any] = [
            LXMessage.FIELD_IMAGE: ["jpeg", jpegData] as [Any]
        ]

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: Data(),
            title: Data(),
            fields: fields,
            desiredMethod: .direct
        )
        _ = try message.pack()

        // Simulate DB storage
        let record = try MessageRecord(from: message)
        XCTAssertEqual(record.packedLxmf.count, message.packed!.count)

        // Simulate DB restore (loadPendingOutbound → toLXMessage)
        let restored = try record.toLXMessage()
        XCTAssertNotNil(restored.packed)
        XCTAssertEqual(restored.packed?.count, message.packed?.count)

        // Verify fields survived
        let restoredImage = restored.fields?[LXMessage.FIELD_IMAGE] as? [Any]
        XCTAssertNotNil(restoredImage)
        XCTAssertEqual((restoredImage?[1] as? Data)?.count, 77404)
    }

    /// Test: handleOutbound with a large image message
    /// Verifies the opportunistic→direct fallback for messages exceeding packet size
    func testHandleOutboundImageFallback() async throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        var jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        jpegData.append(Data(repeating: 0xEF, count: 77400))

        let fields: [UInt8: Any] = [
            LXMessage.FIELD_IMAGE: ["jpeg", jpegData] as [Any]
        ]

        var message = LXMessage(
            destinationHash: destIdentity.hash,
            sourceIdentity: sourceIdentity,
            content: Data(),
            title: Data(),
            fields: fields,
            desiredMethod: .opportunistic
        )
        message.fallbackMethod = .direct

        // Use temp file DB (DatabasePool requires WAL mode, :memory: doesn't support it)
        let tmpDir = FileManager.default.temporaryDirectory
        let dbPath = tmpDir.appendingPathComponent("test_outbound_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        let router = try await LXMRouter(identity: sourceIdentity, databasePath: dbPath)
        try await router.handleOutbound(&message)

        // Should have fallen back to direct (77KB > ENCRYPTED_PACKET_MAX_CONTENT)
        XCTAssertEqual(message.method, .direct, "Should fallback from opportunistic to direct")
        XCTAssertNotNil(message.packed)
        // Without transport, processOutbound can't actually send, but the message
        // should be packed and queued
        XCTAssertTrue(message.state == .outbound || message.state == .sent)

        await router.shutdown()
    }

    /// Test: simulate startup with 8 pending image messages in DB
    /// This is the exact path that caused the crash loop:
    /// 1. Save 8 packed image messages to DB with state=outbound
    /// 2. Create new LXMRouter (loads pending, starts processOutbound)
    /// 3. Run processOutbound cycle (transport=nil, so no delivery)
    /// 4. Verify no crash occurs
    func testStartupWith8PendingImageMessages() async throws {
        let sourceIdentity = Identity()
        let destIdentity = Identity()

        let tmpDir = FileManager.default.temporaryDirectory
        let dbPath = tmpDir.appendingPathComponent("test_startup_\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: dbPath) }

        // Phase 1: Create a DB with 8 pending image messages (simulates the crash state)
        do {
            let db = try LXMFDatabase(path: dbPath)

            for i in 0..<8 {
                var jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
                jpegData.append(Data(repeating: UInt8(i), count: 77400))

                let fields: [UInt8: Any] = [
                    LXMessage.FIELD_IMAGE: ["jpeg", jpegData] as [Any],
                    0x04: ["food-apple", Data([0xFF, 0xFF, 0xFF]), Data([0x1E, 0x88, 0xE5])] as [Any]
                ]

                var message = LXMessage(
                    destinationHash: destIdentity.hash,
                    sourceIdentity: sourceIdentity,
                    content: Data(),
                    title: Data(),
                    fields: fields,
                    desiredMethod: .direct
                )
                _ = try message.pack()

                // Save as outbound (state=1)
                try await db.saveMessage(message)
            }

            // Verify 8 messages in DB
            let pending = try await db.loadPendingOutbound()
            XCTAssertEqual(pending.count, 8, "Should have 8 pending messages")

            // Verify each message has packed data and image field
            for msg in pending {
                XCTAssertNotNil(msg.packed, "Loaded message should have packed data")
                XCTAssertGreaterThan(msg.packed!.count, 77000)
                let imageField = msg.fields?[LXMessage.FIELD_IMAGE] as? [Any]
                XCTAssertNotNil(imageField, "Image field should survive DB round-trip")
            }
        }

        // Phase 2: Simulate app restart — create new router from same DB
        // This is the exact path: LXMRouter.init loads pending, starts processOutbound
        let router = try await LXMRouter(identity: sourceIdentity, databasePath: dbPath)

        // Phase 3: Run a few processOutbound cycles (transport=nil, so all deliveries skip)
        for _ in 0..<3 {
            await router.processOutbound()
        }

        // Phase 4: Verify no crash — if we got here, the bug is reproduced and fixed
        // The messages should still be in pending (can't deliver without transport)
        // or moved to failed (MAX_OUTBOUND_AGE exceeded, though unlikely in test)
        print("[TEST] Startup with 8 pending image messages completed without crash")

        await router.shutdown()
    }
}
