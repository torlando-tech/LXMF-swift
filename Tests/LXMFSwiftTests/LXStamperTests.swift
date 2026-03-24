// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXStamperTests.swift
//  LXMFSwiftTests
//
//  Unit tests for LXStamper proof-of-work implementation.
//  Tests verify exact match with Python LXMF LXStamper.py behavior.
//

import XCTest
import CryptoKit
@testable import LXMFSwift

final class LXStamperTests: XCTestCase {

    private let testMaterial = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])

    // MARK: - Workblock Tests

    /// Test that workblock is exactly 768000 bytes (3000 x 256)
    func testWorkblockSize() {
        let workblock = LXStamper.stampWorkblock(material: testMaterial)
        XCTAssertEqual(workblock.count, 768000, "Workblock must be exactly 768000 bytes (3000 x 256)")
    }

    /// Test that same material produces same workblock
    func testWorkblockDeterministic() {
        let workblock1 = LXStamper.stampWorkblock(material: testMaterial)
        let workblock2 = LXStamper.stampWorkblock(material: testMaterial)
        XCTAssertEqual(workblock1, workblock2, "Workblock must be deterministic for same material")
    }

    /// Test that different materials produce different workblocks
    func testWorkblockDifferentMaterials() {
        let material2 = Data([0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10])
        let workblock1 = LXStamper.stampWorkblock(material: testMaterial)
        let workblock2 = LXStamper.stampWorkblock(material: material2)
        XCTAssertNotEqual(workblock1, workblock2, "Different materials must produce different workblocks")
    }

    /// Test workblock with empty material
    func testWorkblockEmptyMaterial() {
        let emptyMaterial = Data()
        let workblock = LXStamper.stampWorkblock(material: emptyMaterial)
        XCTAssertEqual(workblock.count, 768000, "Workblock size must be 768000 even for empty material")
    }

    /// Test workblock with large material
    func testWorkblockLargeMaterial() {
        let largeMaterial = Data(repeating: 0xAB, count: 10000)
        let workblock = LXStamper.stampWorkblock(material: largeMaterial)
        XCTAssertEqual(workblock.count, 768000, "Workblock size must be 768000 regardless of material size")
    }

    // MARK: - Stamp Validation Tests

    /// Test that generated stamp passes validation
    func testStampValid() {
        let cost = 4
        let workblock = LXStamper.stampWorkblock(material: testMaterial)
        let (stamp, _) = LXStamper.generateStampSync(workblock: workblock, cost: cost)
        XCTAssertTrue(LXStamper.stampValid(stamp: stamp, cost: cost, workblock: workblock),
                      "Valid stamp must pass validation")
    }

    /// Test that random stamps are invalid for high cost
    func testStampInvalid() {
        let cost = 16
        let workblock = LXStamper.stampWorkblock(material: testMaterial)

        // Random stamp is extremely unlikely to be valid for cost 16
        var foundInvalid = false
        for _ in 0..<10 {
            let testStamp = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            if !LXStamper.stampValid(stamp: testStamp, cost: cost, workblock: workblock) {
                foundInvalid = true
                break
            }
        }
        XCTAssertTrue(foundInvalid, "Random stamps should be invalid for cost 16")
    }

    // MARK: - Stamp Value Tests

    /// Test stamp value counts leading zeros
    func testStampValue() {
        let workblock = LXStamper.stampWorkblock(material: testMaterial)
        let (stamp, _) = LXStamper.generateStampSync(workblock: workblock, cost: 4)
        let value = LXStamper.stampValue(workblock: workblock, stamp: stamp)
        XCTAssertGreaterThanOrEqual(value, 4, "Stamp value must be at least the target cost")
    }

    // MARK: - Async Stamp Generation Tests

    /// Test async stamp generation
    func testGenerateStampAsync() async {
        let cost = 4
        let (stamp, rounds) = await LXStamper.generateStamp(messageID: testMaterial, cost: cost)

        XCTAssertGreaterThan(rounds, 0, "Should take at least one round")

        let workblock = LXStamper.stampWorkblock(material: testMaterial)
        XCTAssertTrue(LXStamper.stampValid(stamp: stamp, cost: cost, workblock: workblock),
                      "Generated stamp must pass validation")
    }

    // MARK: - Constants Tests

    /// Test that constants match Python LXMF values
    func testConstants() {
        XCTAssertEqual(LXStamper.EXPAND_ROUNDS, 3000, "EXPAND_ROUNDS should be 3000")
        XCTAssertEqual(LXStamper.EXPAND_LENGTH, 256, "EXPAND_LENGTH should be 256")
        XCTAssertEqual(LXStamper.DEFAULT_COST, 16, "DEFAULT_COST should be 16")
        XCTAssertEqual(LXStamper.COST_TICKET, 0x100, "COST_TICKET should be 256")
        XCTAssertEqual(LXStamper.STAMP_SIZE, 32, "STAMP_SIZE should be 32")
    }
}
