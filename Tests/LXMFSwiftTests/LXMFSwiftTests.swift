// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMFSwiftTests.swift
//  LXMFSwiftTests
//
//  Basic tests for LXMFSwift package.
//

import XCTest
@testable import LXMFSwift

final class LXMFSwiftTests: XCTestCase {

    // MARK: - Message State Tests

    func testMessageStateValues() {
        // Verify raw values match Python LXMF
        XCTAssertEqual(LXMessageState.generating.rawValue, 0x00)
        XCTAssertEqual(LXMessageState.outbound.rawValue, 0x01)
        XCTAssertEqual(LXMessageState.sending.rawValue, 0x02)
        XCTAssertEqual(LXMessageState.sent.rawValue, 0x04)
        XCTAssertEqual(LXMessageState.delivered.rawValue, 0x08)
        XCTAssertEqual(LXMessageState.rejected.rawValue, 0xFD)
        XCTAssertEqual(LXMessageState.cancelled.rawValue, 0xFE)
        XCTAssertEqual(LXMessageState.failed.rawValue, 0xFF)
    }

    func testDeliveryMethodValues() {
        // Verify raw values match Python LXMF
        XCTAssertEqual(LXDeliveryMethod.opportunistic.rawValue, 0x01)
        XCTAssertEqual(LXDeliveryMethod.direct.rawValue, 0x02)
        XCTAssertEqual(LXDeliveryMethod.propagated.rawValue, 0x03)
        XCTAssertEqual(LXDeliveryMethod.paper.rawValue, 0x05)
    }

    // MARK: - Constants Tests

    func testLXMFConstants() {
        // Verify constants match Python LXMF
        XCTAssertEqual(LXMFConstants.DESTINATION_LENGTH, 16)
        XCTAssertEqual(LXMFConstants.SIGNATURE_LENGTH, 64)
        XCTAssertEqual(LXMFConstants.LXMF_OVERHEAD, 112)
        XCTAssertEqual(LXMFConstants.LINK_PACKET_MDU, 431)
        XCTAssertEqual(LXMFConstants.LINK_PACKET_MAX_CONTENT, 319)
    }

    // MARK: - MessagePack Tests

    func testMessagePackNull() throws {
        let packed = packLXMF(.null)
        XCTAssertEqual(packed, Data([0xc0]))

        let unpacked = try unpackLXMF(packed)
        XCTAssertEqual(unpacked, .null)
    }

    func testMessagePackBool() throws {
        let packedTrue = packLXMF(.bool(true))
        XCTAssertEqual(packedTrue, Data([0xc3]))

        let packedFalse = packLXMF(.bool(false))
        XCTAssertEqual(packedFalse, Data([0xc2]))

        let unpackedTrue = try unpackLXMF(packedTrue)
        XCTAssertEqual(unpackedTrue, .bool(true))

        let unpackedFalse = try unpackLXMF(packedFalse)
        XCTAssertEqual(unpackedFalse, .bool(false))
    }

    func testMessagePackFixint() throws {
        // Positive fixint (0-127)
        let packed = packLXMF(.uint(42))
        XCTAssertEqual(packed, Data([42]))

        let unpacked = try unpackLXMF(packed)
        XCTAssertEqual(unpacked, .uint(42))
    }

    func testMessagePackDouble() throws {
        let value = 1234567890.123456
        let packed = packLXMF(.double(value))

        let unpacked = try unpackLXMF(packed)
        if case .double(let result) = unpacked {
            XCTAssertEqual(result, value, accuracy: 0.000001)
        } else {
            XCTFail("Expected double")
        }
    }

    func testMessagePackBinary() throws {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        let packed = packLXMF(.binary(data))

        let unpacked = try unpackLXMF(packed)
        XCTAssertEqual(unpacked, .binary(data))
    }

    func testMessagePackArray() throws {
        let array: [LXMFMessagePackValue] = [
            .uint(1),
            .uint(2),
            .uint(3)
        ]
        let packed = packLXMF(.array(array))

        let unpacked = try unpackLXMF(packed)
        XCTAssertEqual(unpacked, .array(array))
    }

    // MARK: - Version Tests

    func testVersion() {
        XCTAssertFalse(LXMFSwiftVersion.isEmpty)
        XCTAssertEqual(LXMFSwiftBuild.name, "LXMFSwift")
    }
}
