// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouterFailoverTests.swift
//  LXMFSwiftTests
//
//  Coverage for the transport-event failover machinery:
//    - handleDirectPathLost: link eviction, establishment cancellation,
//      pendingOutbound re-arming, sent-but-unproven rescue
//    - awaitingConfirmation deadline sweep
//    - late-proof race safety (no duplicate send after rescue)
//    - tryPropagationOnFail: same-message switch to .propagated
//    - setNearbyDestinations forwarding + replay across setTransport
//

import XCTest
@testable import LXMFSwift
import ReticulumSwift

final class LXMRouterFailoverTests: XCTestCase {

    // MARK: - Helpers

    private func makeRouter() async throws -> LXMRouter {
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf-failover-tests-\(UUID().uuidString).db")
            .path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dbPath) }
        return try await LXMRouter(identity: Identity(), databasePath: dbPath)
    }

    private func makeMessage(
        dest: Data? = nil,
        method: LXDeliveryMethod = .direct
    ) throws -> LXMessage {
        var msg = LXMessage(
            destinationHash: dest ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
            sourceIdentity: Identity(),
            content: Data("failover-test".utf8),
            title: Data(),
            fields: nil,
            desiredMethod: method
        )
        _ = try msg.pack()
        return msg
    }

    // MARK: - handleDirectPathLost

    /// Queued messages for the lost destination get an immediate retry
    /// slot without consuming a delivery attempt.
    func testDirectPathLostReArmsPendingOutbound() async throws {
        let router = try await makeRouter()
        var msg = try makeMessage()
        msg.deliveryAttempts = 3
        msg.nextDeliveryAttempt = Date().addingTimeInterval(120)  // far future
        await router.failoverTestAppendPendingOutbound(msg)

        // Unrelated destination must stay untouched.
        var other = try makeMessage()
        let otherNext = Date().addingTimeInterval(120)
        other.nextDeliveryAttempt = otherNext
        await router.failoverTestAppendPendingOutbound(other)

        await router.handleDirectPathLost(destination: msg.destinationHash)

        let rearmed = await router.failoverTestPendingOutbound(forHash: msg.hash)
        XCTAssertNotNil(rearmed)
        XCTAssertLessThanOrEqual(rearmed!.nextDeliveryAttempt ?? .distantFuture, Date(),
            "Path loss must re-arm the message for an immediate retry")
        XCTAssertEqual(rearmed!.deliveryAttempts, 3,
            "Re-arming must not consume a delivery attempt — the path change isn't the message's fault")

        let untouched = await router.failoverTestPendingOutbound(forHash: other.hash)
        XCTAssertEqual(untouched?.nextDeliveryAttempt, otherNext,
            "Messages to other destinations must not be re-armed")
    }

    /// The cached link is evicted and an in-flight establishment task is
    /// cancelled so awaiting senders fail fast.
    func testDirectPathLostEvictsLinkAndCancelsEstablishment() async throws {
        let router = try await makeRouter()
        let dest = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

        let link = Link(
            destination: Destination(identity: Identity(), appName: "test", aspects: ["failover"]),
            identity: Identity(),
            hwMtu: nil
        )
        await router.failoverTestSetDeliveryLink(dest: dest, link: link)

        let establishment: Task<Link, Error> = Task {
            // Simulates a long-running establishment; cancellation is the
            // only way out before the sleep elapses.
            try await Task.sleep(for: .seconds(60))
            throw LXMFError.linkFailed("should have been cancelled")
        }
        await router.failoverTestSetEstablishmentTask(dest: dest, task: establishment)

        await router.handleDirectPathLost(destination: dest)

        let hasLink = await router.failoverTestHasDeliveryLink(dest: dest)
        XCTAssertFalse(hasLink, "Dead link must be evicted from deliveryLinks")
        let hasTask = await router.failoverTestHasEstablishmentTask(dest: dest)
        XCTAssertFalse(hasTask, "In-flight establishment must be removed")
        XCTAssertTrue(establishment.isCancelled, "In-flight establishment must be cancelled")
    }

    // MARK: - Sent-but-unproven rescue

    /// A message stuck at .sent (proof never arrived) is rescued back
    /// into pendingOutbound when the path to its destination dies.
    func testSentUnprovenMessageRescuedOnPathLost() async throws {
        let router = try await makeRouter()
        var msg = try makeMessage()
        msg.state = .sent
        msg.deliveryAttempts = 2
        await router.failoverTestSaveMessage(msg)
        await router.failoverTestTrackConfirmation(
            messageHash: msg.hash,
            destinationHash: msg.destinationHash,
            packetTruncatedHash: Data(repeating: 0x01, count: 16),
            deadline: Date().addingTimeInterval(45)  // not yet expired
        )

        await router.handleDirectPathLost(destination: msg.destinationHash)

        let rescued = await router.failoverTestPendingOutbound(forHash: msg.hash)
        XCTAssertNotNil(rescued, "Sent-but-unproven message must be rescued into pendingOutbound")
        XCTAssertEqual(rescued?.state, .outbound)
        XCTAssertEqual(rescued?.deliveryAttempts, 2,
            "Rescue must preserve the persisted attempt count so MAX_DELIVERY_ATTEMPTS still bounds total work")
        let tracked = await router.failoverTestAwaitingConfirmationCount
        XCTAssertEqual(tracked, 0, "Rescued entry must leave awaitingConfirmation")

        // Late proof race: the proof for the ORIGINAL send arrives after
        // the rescue. The rescued in-memory copy must flip to .delivered
        // (so processOutbound drops it) — no duplicate send, no failure.
        await router.handleDeliveryProofReceived(messageHash: msg.hash)
        let afterProof = await router.failoverTestPendingOutbound(forHash: msg.hash)
        XCTAssertEqual(afterProof?.state, .delivered,
            "Late proof must flip the rescued copy to .delivered so it is dropped, not re-sent")
    }

    /// The deadline sweep (no transport event) rescues expired entries
    /// and leaves unexpired ones tracked.
    func testConfirmationDeadlineRescue() async throws {
        let router = try await makeRouter()

        var expired = try makeMessage()
        expired.state = .sent
        await router.failoverTestSaveMessage(expired)
        await router.failoverTestTrackConfirmation(
            messageHash: expired.hash,
            destinationHash: expired.destinationHash,
            packetTruncatedHash: Data(repeating: 0x02, count: 16),
            deadline: Date().addingTimeInterval(-1)  // already expired
        )

        var fresh = try makeMessage()
        fresh.state = .sent
        await router.failoverTestSaveMessage(fresh)
        await router.failoverTestTrackConfirmation(
            messageHash: fresh.hash,
            destinationHash: fresh.destinationHash,
            packetTruncatedHash: Data(repeating: 0x03, count: 16),
            deadline: Date().addingTimeInterval(60)
        )

        let rescuedCount = await router.rescueUnconfirmedMessages(destination: nil)
        XCTAssertEqual(rescuedCount, 1, "Only the expired entry should be rescued")

        let rescuedMsg = await router.failoverTestPendingOutbound(forHash: expired.hash)
        XCTAssertEqual(rescuedMsg?.state, .outbound)
        let freshStillPending = await router.failoverTestPendingOutbound(forHash: fresh.hash)
        XCTAssertNil(freshStillPending, "Unexpired entry must not be rescued")
        let tracked = await router.failoverTestAwaitingConfirmationCount
        XCTAssertEqual(tracked, 1, "Unexpired entry must remain tracked")
    }

    /// A message whose DB state is already .delivered (proof landed via
    /// another path) must never be rescued into a re-send.
    func testRescueSkipsDeliveredMessage() async throws {
        let router = try await makeRouter()
        var msg = try makeMessage()
        msg.state = .delivered
        await router.failoverTestSaveMessage(msg)
        await router.failoverTestTrackConfirmation(
            messageHash: msg.hash,
            destinationHash: msg.destinationHash,
            packetTruncatedHash: Data(repeating: 0x04, count: 16),
            deadline: Date().addingTimeInterval(-1)
        )

        let rescuedCount = await router.rescueUnconfirmedMessages(destination: nil)
        XCTAssertEqual(rescuedCount, 0)
        let inQueue = await router.failoverTestPendingOutbound(forHash: msg.hash)
        XCTAssertNil(inQueue, "Delivered message must never be re-enqueued")
    }

    /// Proof arrival stops tracking, so a later path-lost event has
    /// nothing to rescue.
    func testProofClearsConfirmationTracking() async throws {
        let router = try await makeRouter()
        var msg = try makeMessage()
        msg.state = .sent
        await router.failoverTestSaveMessage(msg)
        await router.failoverTestTrackConfirmation(
            messageHash: msg.hash,
            destinationHash: msg.destinationHash,
            packetTruncatedHash: Data(repeating: 0x05, count: 16),
            deadline: Date().addingTimeInterval(45)
        )

        await router.handleDeliveryProofReceived(messageHash: msg.hash)
        let tracked = await router.failoverTestAwaitingConfirmationCount
        XCTAssertEqual(tracked, 0, "Proof must clear the confirmation tracking")

        await router.handleDirectPathLost(destination: msg.destinationHash)
        let inQueue = await router.failoverTestPendingOutbound(forHash: msg.hash)
        XCTAssertNil(inQueue, "Nothing to rescue after the proof arrived")
    }

    // MARK: - tryPropagationOnFail

    /// A message that exhausts MAX_DELIVERY_ATTEMPTS with
    /// tryPropagationOnFail set switches the SAME message to .propagated
    /// (attempts reset, no didFailMessage) instead of failing.
    func testTryPropagationOnFailSwitchesMethod() async throws {
        let router = try await makeRouter()
        await router.setOutboundPropagationNode(Data((0..<16).map { _ in 0xEE }))

        var msg = try makeMessage(method: .direct)
        msg.tryPropagationOnFail = true
        msg.deliveryAttempts = LXMRouter.MAX_DELIVERY_ATTEMPTS
        await router.failoverTestSaveMessage(msg)
        await router.failoverTestAppendPendingOutbound(msg)

        let recorder = await MainActor.run { FailoverFailureRecorder() }
        await router.setDelegate(recorder)

        await router.processOutbound()
        await router.shutdown()

        let switched = await router.failoverTestPendingOutbound(forHash: msg.hash)
        XCTAssertNotNil(switched, "Message must stay in the queue (as .propagated), not move to failed")
        XCTAssertEqual(switched?.method, .propagated,
            "Same message must switch to .propagated — no second message/bubble")
        XCTAssertEqual(switched?.deliveryAttempts, 0,
            "Propagation path gets its own attempt budget")
        XCTAssertEqual(switched?.state, .outbound)

        try await Task.sleep(nanoseconds: 100_000_000)
        let failures = await MainActor.run { recorder.failures }
        XCTAssertEqual(failures.count, 0,
            "Switching to propagation must NOT fire didFailMessage")
    }

    /// Without tryPropagationOnFail the message still fails terminally
    /// (regression guard for the new branch).
    func testMaxAttemptsStillFailsWithoutTryPropagationOnFail() async throws {
        let router = try await makeRouter()
        await router.setOutboundPropagationNode(Data((0..<16).map { _ in 0xEE }))

        var msg = try makeMessage(method: .direct)
        msg.deliveryAttempts = LXMRouter.MAX_DELIVERY_ATTEMPTS
        await router.failoverTestSaveMessage(msg)
        await router.failoverTestAppendPendingOutbound(msg)

        let recorder = await MainActor.run { FailoverFailureRecorder() }
        await router.setDelegate(recorder)

        await router.processOutbound()
        await router.shutdown()

        let gone = await router.failoverTestPendingOutbound(forHash: msg.hash)
        XCTAssertNil(gone, "Exhausted message without the flag must leave the queue")
        try await Task.sleep(nanoseconds: 100_000_000)
        let failures = await MainActor.run { recorder.failures }
        XCTAssertEqual(failures.count, 1, "didFailMessage must fire exactly once")
    }

    // MARK: - Nearby passthrough

    /// setNearbyDestinations forwards to the transport, and a hint set
    /// BEFORE the transport attaches is replayed on setTransport.
    func testSetNearbyDestinationsForwardsAndReplays() async throws {
        let router = try await makeRouter()
        let dest = Data((0..<16).map { _ in 0x44 })

        // Hint set before transport attach.
        await router.setNearbyDestinations([dest])

        let transport = ReticulumTransport()
        await router.setTransport(transport)
        let replayed = await transport.getNearbyDestinations()
        XCTAssertEqual(replayed, [dest], "Pre-attach hint must be replayed on setTransport")

        // Subsequent updates forward live.
        let dest2 = Data((0..<16).map { _ in 0x55 })
        await router.setNearbyDestinations([dest2])
        let forwarded = await transport.getNearbyDestinations()
        XCTAssertEqual(forwarded, [dest2])
    }
}

// MARK: - Test-only LXMRouter helpers (failover)

extension LXMRouter {
    fileprivate func failoverTestAppendPendingOutbound(_ message: LXMessage) {
        pendingOutbound.append(message)
    }

    fileprivate func failoverTestPendingOutbound(forHash hash: Data) -> LXMessage? {
        pendingOutbound.first(where: { $0.hash == hash })
    }

    fileprivate func failoverTestSaveMessage(_ message: LXMessage) async {
        try? await database.saveMessage(message)
    }

    fileprivate func failoverTestSetDeliveryLink(dest: Data, link: Link) {
        deliveryLinks[dest] = link
    }

    fileprivate func failoverTestHasDeliveryLink(dest: Data) -> Bool {
        deliveryLinks[dest] != nil
    }

    fileprivate func failoverTestSetEstablishmentTask(dest: Data, task: Task<Link, Error>) {
        establishmentTasks[dest] = task
    }

    fileprivate func failoverTestHasEstablishmentTask(dest: Data) -> Bool {
        establishmentTasks[dest] != nil
    }

    fileprivate func failoverTestTrackConfirmation(
        messageHash: Data, destinationHash: Data,
        packetTruncatedHash: Data, deadline: Date
    ) {
        awaitingConfirmation[messageHash] = PendingConfirmation(
            destinationHash: destinationHash,
            packetTruncatedHash: packetTruncatedHash,
            deadline: deadline
        )
    }

    fileprivate var failoverTestAwaitingConfirmationCount: Int {
        awaitingConfirmation.count
    }
}

/// Records didFailMessage callbacks (separate type from the one in
/// LXMRouterProofCallbackTests — fileprivate types don't cross files).
@MainActor
private final class FailoverFailureRecorder: LXMRouterDelegate {
    struct Failure {
        let hash: Data
        let reason: LXMFError
    }
    var failures: [Failure] = []
    nonisolated func router(_ router: LXMRouter, didFailMessage message: LXMessage, reason: LXMFError) {
        Task { @MainActor in
            failures.append(Failure(hash: message.hash, reason: reason))
        }
    }
}
