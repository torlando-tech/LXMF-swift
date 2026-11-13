//
//  PinChangeTests.swift
//  LXMFSwiftTests
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class PinChangeTests: XCTestCase {
    private func temporaryPath(_ name: String) -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-change-tests-\(UUID().uuidString)-\(name)")
            .path
        addTeardownBlock {
            try? FileManager.default.removeItem(atPath: path)
        }
        return path
    }

    private func makeDatabase() throws -> LXMFDatabase {
        try LXMFDatabase(path: temporaryPath("live.db"))
    }

    private func savedMessage(_ db: LXMFDatabase, to destination: Data) async throws -> LXMessage {
        var message = LXMessage(destinationHash: destination,
                                sourceIdentity: Identity(),
                                content: Data("pin me".utf8),
                                title: Data(),
                                fields: nil,
                                desiredMethod: .direct)
        _ = try message.pack()
        try await db.saveMessage(message)
        return message
    }

    private func change(target: Data,
                        in conversation: Data,
                        actor: Data = Data(repeating: 0xA1, count: 16),
                        isPinned: Bool = true,
                        timestamp: Double = 100,
                        placedAt: Double = 100) -> PinChangeRecord {
        PinChangeRecord(hash: Data((0..<32).map { (_: Int) in UInt8.random(in: 0...255) }),
                        conversationHash: conversation,
                        target: target,
                        actor: actor,
                        isPinned: isPinned,
                        timestamp: timestamp,
                        placedAt: placedAt)
    }

    // MARK: - Schema

    func testMigrationCreatesTableAndRestoreForwardMigrates() async throws {
        let db = try makeDatabase()
        let conversation = Identity().hash
        let isNewOnFresh = try await db.savePinChange(change(target: Data(repeating: 1, count: 32), in: conversation))
        XCTAssertTrue(isNewOnFresh)

        let empty = temporaryPath("empty.db")
        FileManager.default.createFile(atPath: empty, contents: nil)
        try await db.importDatabase(from: empty)
        let isNewAfterRestore = try await db.savePinChange(change(target: Data(repeating: 2, count: 32), in: conversation))
        XCTAssertTrue(isNewAfterRestore)
    }

    // MARK: - Writing

    func testSaveIsIdempotentByHash() async throws {
        let db = try makeDatabase()
        let conversation = Identity().hash
        let record = change(target: Data(repeating: 1, count: 32), in: conversation)

        let isFirstNew = try await db.savePinChange(record)
        let isSecondNew = try await db.savePinChange(record)

        XCTAssertTrue(isFirstNew)
        XCTAssertFalse(isSecondNew)
        let stored = try await db.pinChanges(forConversation: conversation)
        XCTAssertEqual(stored, [record])
    }

    // MARK: - Lines

    func testLinesNeedTheTargetInTheSameConversation() async throws {
        let db = try makeDatabase()
        let conversation = Identity().hash
        let elsewhere = try await savedMessage(db, to: Identity().hash)
        let missingTarget = Data(repeating: 7, count: 32)
        _ = try await db.savePinChange(change(target: elsewhere.hash, in: conversation))
        let waiting = change(target: missingTarget, in: conversation, placedAt: 200)
        _ = try await db.savePinChange(waiting)

        let linesBefore = try await db.pinLines(forConversation: conversation)
        XCTAssertEqual(linesBefore, [])

        var arrived = LXMessage(destinationHash: conversation,
                                sourceIdentity: Identity(),
                                content: Data("late".utf8),
                                title: Data(),
                                fields: nil,
                                desiredMethod: .direct)
        _ = try arrived.pack()
        let landed = change(target: arrived.hash, in: conversation, placedAt: 300)
        _ = try await db.savePinChange(landed)
        try await db.saveMessage(arrived)

        let linesAfter = try await db.pinLines(forConversation: conversation)
        XCTAssertEqual(linesAfter, [landed])
    }

    func testLatestPinLinesGivesOnePerConversation() async throws {
        let db = try makeDatabase()
        var newest: [Data: PinChangeRecord] = [:]
        for _ in 0..<2 {
            let conversation = Identity().hash
            let message = try await savedMessage(db, to: conversation)
            for placedAt in [10.0, 30.0, 20.0] {
                let line = change(target: message.hash, in: conversation, timestamp: placedAt, placedAt: placedAt)
                _ = try await db.savePinChange(line)
                if placedAt == 30 { newest[conversation] = line }
            }
        }

        let latest = try await db.latestPinLines()

        XCTAssertEqual(latest.count, 2)
        XCTAssertEqual(Set(latest.map { (line: PinChangeRecord) in line.hash }),
                       Set(newest.values.map { (line: PinChangeRecord) in line.hash }))
    }

    // MARK: - Waiting

    func testWaitingCountAndPrune() async throws {
        let db = try makeDatabase()
        let conversation = Identity().hash
        let actor = Data(repeating: 0xA1, count: 16)
        let message = try await savedMessage(db, to: conversation)
        _ = try await db.savePinChange(change(target: Data(repeating: 1, count: 32), in: conversation, actor: actor, timestamp: 50))
        _ = try await db.savePinChange(change(target: Data(repeating: 2, count: 32), in: conversation, actor: actor, timestamp: 150))
        let line = change(target: message.hash, in: conversation, actor: actor, timestamp: 10)
        _ = try await db.savePinChange(line)

        let waiting = try await db.waitingPinChangeCount(fromActor: actor)
        XCTAssertEqual(waiting, 2)

        let pruned = try await db.deleteWaitingPinChanges(olderThan: 100)

        XCTAssertEqual(pruned, 1)
        let remainingWaiting = try await db.waitingPinChangeCount(fromActor: actor)
        XCTAssertEqual(remainingWaiting, 1)
        let lines = try await db.pinLines(forConversation: conversation)
        XCTAssertEqual(lines, [line])
    }

    // MARK: - Deleting

    func testDeleteConversationAndDeleteMessageRemoveRows() async throws {
        let db = try makeDatabase()
        let kept = Identity().hash
        let removed = Identity().hash
        let keptMessage = try await savedMessage(db, to: kept)
        let removedMessage = try await savedMessage(db, to: removed)
        let keptChange = change(target: keptMessage.hash, in: kept)
        _ = try await db.savePinChange(keptChange)
        _ = try await db.savePinChange(change(target: removedMessage.hash, in: removed))

        try await db.deleteConversation(hash: removed)
        let removedRows = try await db.pinChanges(forConversation: removed)
        XCTAssertEqual(removedRows, [])

        try await db.deleteMessage(id: keptChange.hash)
        let afterEnvelopeDiscard = try await db.pinChanges(forConversation: kept)
        XCTAssertEqual(afterEnvelopeDiscard, [keptChange])

        try await db.deleteMessage(id: keptMessage.hash)
        let afterTargetDelete = try await db.pinChanges(forTarget: keptMessage.hash)
        XCTAssertEqual(afterTargetDelete, [])
    }
}
