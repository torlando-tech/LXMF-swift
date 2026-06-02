// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  DeliveredTransientIDPersistenceTests.swift
//  LXMFSwiftTests
//
//  Pins the durable duplicate-delivery dedup (faithful port of python's persisted
//  locally_delivered_transient_ids / local_deliveries, LXMRouter.py:212-216 + :1177-1184):
//  a transient id recorded as delivered survives a router "restart" so a duplicate
//  re-delivery after a process restart is still rejected. Previously the cache was
//  in-memory only and reset on every launch.
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class DeliveredTransientIDPersistenceTests: XCTestCase {

    func testDedupPersistsAcrossRouterRestart() async throws {
        let dir = NSTemporaryDirectory() + "lxmf-dedup-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let dbPath = dir + "lxmf-swift.db"
        let identity = Identity()
        let transientID = Data(repeating: 0xAB, count: 32)

        // Router #1 records a delivery → persists <dir>/local_deliveries.
        let r1 = try await LXMRouter(identity: identity, databasePath: dbPath)
        await r1.recordDelivered(transientID)
        let inCache = await r1.deliveredTransientIDs[transientID]
        XCTAssertNotNil(inCache, "recordDelivered must populate the in-memory cache")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "local_deliveries"),
                      "recordDelivered must persist local_deliveries next to the DB")

        // Router #2 on the same path loads the persisted dedup (survives a restart).
        let r2 = try await LXMRouter(identity: identity, databasePath: dbPath)
        let restored = await r2.deliveredTransientIDs[transientID]
        XCTAssertNotNil(restored, "duplicate-delivery cache must persist across router restart")
    }
}
