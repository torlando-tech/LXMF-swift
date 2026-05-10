// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMRouter.swift
//  LXMFSwift
//
//  LXMF message router with in-memory queues, outbound processing, and delivery callbacks.
//  Matches Python LXMF LXMRouter pattern for message routing and delivery.
//
//  Reference: LXMF/LXMRouter.py
//  - handleOutbound: lines 1627-1672
//  - lxmfDelivery: lines 1714-1799
//  - processOutbound: lines 2496-2700
//

import Foundation
import CryptoKit
import ReticulumSwift
import os.log

private let routerLogger = Logger(subsystem: "net.reticulum.lxmf", category: "LXMRouter")

/// LXMF message router actor.
///
/// Manages outbound message queues, processes delivery attempts, handles incoming messages,
/// and invokes delegate callbacks. Uses in-memory arrays as primary queue with database persistence.
///
/// Queue pattern (from research):
/// - In-memory arrays (pendingOutbound, failedOutbound) are PRIMARY
/// - Database provides persistence across restarts
/// - Load from database on startup
/// - Persist changes async (non-blocking)
public actor LXMRouter {

    // MARK: - Constants

    /// Maximum delivery attempts before moving to failed queue
    public static let MAX_DELIVERY_ATTEMPTS = 8

    /// Maximum delivery attempts without path before requesting path
    public static let MAX_PATHLESS_TRIES = 4

    /// Time to wait after requesting path before next attempt
    public static let PATH_REQUEST_WAIT: TimeInterval = 15

    /// Interval between outbound processing cycles
    public static let PROCESSING_INTERVAL: TimeInterval = 1

    /// Duplicate detection cache expiry (1 hour)
    public static let DUPLICATE_CACHE_EXPIRY: TimeInterval = 3600

    /// Maximum age (seconds) for pending outbound messages before marking as failed.
    /// Prevents crash loops from stuck messages that can never be delivered.
    /// Set high (24h) to avoid prematurely failing messages on slow mesh networks.
    public static let MAX_OUTBOUND_AGE: TimeInterval = 86400  // 24 hours

    // MARK: - Properties

    /// Local identity for signing outbound messages
    public let identity: Identity

    /// Database for message persistence
    internal let database: LXMFDatabase

    /// In-memory pending outbound queue (PRIMARY).
    /// `internal` (not `private`) so cross-file extensions in this module
    /// can read/mutate it — specifically `LXMRouter+Propagation.swift`'s
    /// `handlePropagationSignalingPacket` needs to flip the most recent
    /// in-flight propagated message to `.rejected` when the propagation
    /// node sends `LXMPeer.ERROR_INVALID_STAMP` over the link's packet
    /// callback.
    internal var pendingOutbound: [LXMessage] = []

    /// In-memory failed outbound queue
    private var failedOutbound: [LXMessage] = []

    /// Duplicate detection cache: transient ID -> timestamp
    /// Transient ID is message.hash (32 bytes)
    /// Cached for 1 hour to prevent processing duplicates
    var deliveredTransientIDs: [Data: Date] = [:]

    /// Cached stamp costs from announces: destination_hash -> (timestamp, cost)
    public var outboundStampCosts: [Data: (Date, Int)] = [:]

    /// Reentrancy guard for processOutbound
    public var processingOutbound: Bool = false

    /// Flag to stop the processing loop (for shutdown)
    private var isShutdown: Bool = false

    /// Delegate for message callbacks (wrapper holds weak reference to delegate)
    public var delegateWrapper: DelegateWrapper?

    /// Transport for message delivery (optional, set via setTransport)
    public var transport: ReticulumTransport?

    /// Path table for route lookup (accessed via transport)
    public var pathTable: PathTable?

    /// Active and pending links for direct delivery
    public var deliveryLinks: [Data: Link] = [:]

    /// Map outbound resource hash → message hash for delivery confirmation.
    /// When RESOURCE_PRF is received, we look up the message hash here to mark it delivered.
    public var pendingResourceDeliveries: [Data: Data] = [:]

    /// Outbound resource hashes that correspond to PROPAGATED messages.
    ///
    /// Membership in this set causes `handleResourceTransferComplete` to
    /// treat RESOURCE_PRF as "propagation node accepted the upload" rather
    /// than "recipient acked delivery". The end-state distinction matches
    /// python `LXMessage.__mark_propagated` (LXMF/LXMessage.py:568-578)
    /// which caps PROPAGATED at `state = SENT`, vs `__mark_delivered`
    /// (LXMessage.py:556-566) which advances OPP/DIRECT to DELIVERED.
    /// Without this set, large PROPAGATED messages (which use Resource
    /// transfer rather than the small-packet path at
    /// LXMRouter+Propagation.swift:173-216) incorrectly advance to
    /// DELIVERED in the iOS UI — the sender NEVER learns when the
    /// recipient syncs the message down from the propagation node, so
    /// claiming "delivered" is a false positive.
    public var pendingPropagationResources: Set<Data> = []

    /// Active propagation links (separate cache from delivery links)
    public var propagationLinks: [Data: Link] = [:]

    /// Outbound propagation node hash (16 bytes).
    /// When set, .propagated delivery sends messages to this node.
    public var outboundPropagationNode: Data?

    /// Cross-actor setter for `outboundPropagationNode`. Convenience
    /// wrapper so callers don't need `await router.outboundPropagationNode = ...`
    /// (which is not currently allowed for actor-isolated `var`s from
    /// outside the actor).
    public func setOutboundPropagationNode(_ destinationHash: Data?) {
        outboundPropagationNode = destinationHash
    }

    /// Cross-actor setter for `propagationStampCost`. Same rationale as
    /// `setOutboundPropagationNode` — exposed so test harnesses can pin
    /// the stamp cost manually instead of waiting for it to be derived
    /// from the propagation node's announce app-data.
    public func setPropagationStampCost(_ cost: Int) {
        propagationStampCost = cost
    }

    /// Stamp cost required by the selected propagation node.
    /// Set when selecting a propagation node (from PropagationNodeInfo.stampCost).
    /// 0 = no stamp work required (any 32-byte stamp accepted).
    public var propagationStampCost: Int = 0

    /// Current sync state for UI observation.
    public var syncState = PropagationTransferState()

    /// Registered delivery destinations
    public var deliveryDestinations: [Data: (Destination, Int?)] = [:]

    /// Ratchet manager for forward secrecy on inbound message decryption.
    /// Set from AppServices after enabling ratchets on the delivery destination.
    public var ratchetManager: RatchetManager?

    /// Identity recall cache: identity hash -> Identity
    /// Used to look up source identities for signature validation during unpack.
    /// Populated by registerIdentity() or from announces.
    private var identityCache: [Data: Identity] = [:]

    // MARK: - Delegate Wrapper

    /// Wrapper for weak delegate reference in actor context.
    ///
    /// Swift actors can't directly hold weak references to @MainActor protocols,
    /// so we use a class wrapper to hold the weak reference.
    public class DelegateWrapper: @unchecked Sendable {
        public weak var delegate: LXMRouterDelegate?

        public init(delegate: LXMRouterDelegate) {
            self.delegate = delegate
        }
    }

    // MARK: - Initialization

    /// Create LXMF router.
    ///
    /// - Parameters:
    ///   - identity: Local identity for signing outbound messages
    ///   - databasePath: Path to SQLite database (use ":memory:" for testing)
    /// - Throws: DatabaseError if database initialization fails
    public init(identity: Identity, databasePath: String) async throws {
        self.identity = identity
        self.database = try LXMFDatabase(path: databasePath)

        // Load pending outbound from database (restore after crash/restart)
        // Wrapped in do/catch to prevent corrupt messages from crashing init
        do {
            let pending = try await database.loadPendingOutbound()
            self.pendingOutbound = pending
        } catch {
            routerLogger.warning("Failed to load pending outbound: \(error). Starting with empty queue.")
            self.pendingOutbound = []
        }

        // Load failed outbound from database
        do {
            let failed = try await database.loadFailedOutbound()
            self.failedOutbound = failed
        } catch {
            routerLogger.warning("Failed to load failed outbound: \(error). Starting with empty queue.")
            self.failedOutbound = []
        }

        // Start the outbound processing loop if there are pending messages
        if !pendingOutbound.isEmpty {
            routerLogger.info("Starting outbound processor with \(self.pendingOutbound.count) pending messages")
            Task {
                await processOutbound()
            }
        }
    }

    // MARK: - Delegate Management

    /// Set the router delegate.
    ///
    /// - Parameter delegate: Delegate to receive callbacks (held weakly)
    public func setDelegate(_ delegate: LXMRouterDelegate?) {
        if let delegate = delegate {
            self.delegateWrapper = DelegateWrapper(delegate: delegate)
        } else {
            self.delegateWrapper = nil
        }
    }

    // MARK: - Lifecycle Management

    /// Shutdown the router, stopping the processing loop.
    ///
    /// Call this when the router is no longer needed to clean up background tasks.
    public func shutdown() {
        isShutdown = true
    }

    /// Restart the router after a shutdown.
    ///
    /// Call this after reconnection to re-enable message processing.
    /// The router must have a new transport set before calling this.
    public func restart() {
        isShutdown = false
    }

    // MARK: - Transport Management

    /// Set the transport for message delivery.
    ///
    /// - Parameter transport: ReticulumTransport instance for sending packets
    public func setTransport(_ transport: ReticulumTransport) async {
        self.transport = transport
        // Access path table from transport for route lookups
        self.pathTable = await transport.getPathTable()
    }

    /// Set the ratchet manager for forward secrecy on sync decryption.
    ///
    /// - Parameter manager: The ratchet manager (or nil to disable)
    public func setRatchetManager(_ manager: RatchetManager?) {
        self.ratchetManager = manager
    }

    // MARK: - Identity Management

    /// Register an identity for signature validation.
    ///
    /// When a message is received, the router looks up the source identity from
    /// this cache to validate the signature. Identities are typically registered
    /// from received announces.
    ///
    /// - Parameter identity: Identity to register
    public func registerIdentity(_ identity: Identity) {
        // Store under LXMF delivery destination hash (not raw identity hash)
        // This matches Python's Identity.recall() which uses destination hash
        let destHash = Destination.hash(identity: identity, appName: "lxmf", aspects: ["delivery"])
        identityCache[destHash] = identity
    }

    /// Recall an identity by its hash.
    ///
    /// - Parameter hash: Identity hash (16 bytes)
    /// - Returns: Identity if found in cache, nil otherwise
    public func recallIdentity(_ hash: Data) -> Identity? {
        return identityCache[hash]
    }

    // MARK: - Outbound Message Handling

    /// Handle outbound message.
    ///
    /// Sets state to OUTBOUND, packs the message (generates hash and signature),
    /// adds to pending queue, persists to database, and triggers processing.
    ///
    /// - Parameter message: Message to send (must have sourceIdentity)
    /// - Throws: LXMFError if packing fails
    ///
    /// Reference: Python LXMRouter.handle_outbound() lines 1627-1672
    public func handleOutbound(_ message: inout LXMessage) async throws {
        // Set state to OUTBOUND
        message.state = .outbound

        // Check for cached stamp cost for destination
        if let (_, _) = outboundStampCosts[message.destinationHash] {
            // TODO: Apply stamp cost from announce (deferred to stamping plan)
            // For now, messages are sent without stamps
        }

        // Pack message (generates hash and signature)
        if message.packed == nil {
            _ = try message.pack()
        }

        // Auto-fallback from opportunistic if message exceeds single-packet limit.
        // For opportunistic, the data sent is packed[DEST_LENGTH:] which must fit in a single
        // encrypted RNS packet. If too large, use the fallbackMethod (.direct or .propagated).
        // Reference: Python LXMessage.pack() lines 400-406
        if message.method == .opportunistic, let packed = message.packed {
            let packedPayloadSize = packed.count - (2 * LXMFConstants.DESTINATION_LENGTH + LXMFConstants.SIGNATURE_LENGTH)
            if packedPayloadSize > LXMFConstants.ENCRYPTED_PACKET_MAX_CONTENT {
                let fallback = message.fallbackMethod ?? .direct
                routerLogger.info("Message too large for opportunistic (\(packedPayloadSize) > \(LXMFConstants.ENCRYPTED_PACKET_MAX_CONTENT)), falling back to \(String(describing: fallback))")
                message.method = fallback
            } else {
                routerLogger.info("Message fits in opportunistic: \(packedPayloadSize) bytes")
            }
        }

        // Add to pending outbound queue
        pendingOutbound.append(message)

        // Persist to database before processing so the message survives force-quit
        do {
            try await database.saveMessage(message)
        } catch {
            routerLogger.error("Failed to persist message: \(error)")
        }

        // Trigger outbound processing
        await processOutbound()
    }

    // MARK: - Inbound Message Handling

    /// Handle incoming LXMF message delivery.
    ///
    /// Unpacks message, validates signature, checks for duplicates, validates stamp if required,
    /// stores in database, updates conversation, and invokes delegate callback.
    ///
    /// - Parameters:
    ///   - data: Packed LXMF wire format
    ///   - physicalStats: Optional physical layer statistics (RSSI, SNR, Q)
    ///   - method: Delivery method actually used to receive this message
    ///     (`.opportunistic` for single-packet delivery, `.direct` for link delivery,
    ///     `.propagated` for messages pulled from a propagation node). When nil,
    ///     the value defaulted by `LXMessage.unpackFromBytes` is preserved.
    /// - Returns: True if message was accepted, false if rejected (duplicate, invalid signature, etc.)
    ///
    /// Reference: Python LXMRouter.lxmf_delivery() lines 1730-1815 (which takes a `method` kwarg
    /// and assigns `message.method = method` when provided).
    @discardableResult
    public func lxmfDelivery(
        _ data: Data,
        physicalStats: PhysicalStats? = nil,
        method: LXDeliveryMethod? = nil
    ) async -> Bool {
        let dataHex = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        routerLogger.info("Entry: \(data.count) bytes, prefix=\(dataHex), method=\(String(describing: method))")

        do {
            // Extract source hash to look up identity for signature validation
            // LXMF format: [dest_hash 16B][src_hash 16B][signature 64B][payload...]
            guard data.count >= 32 else {
                routerLogger.warning("REJECTED: too short (\(data.count) < 32)")
                return false
            }
            let destinationHash = data.subdata(in: 0..<16)
            let sourceHash = data.subdata(in: 16..<32)
            let srcHex = sourceHash.prefix(4).map { String(format: "%02x", $0) }.joined()

            // Self-echo detection: a TCP relay broadcasts every packet
            // to all connected clients including the original sender,
            // so our own outbound LXMF messages echo back as inbound.
            // The original fix (LXMF-swift commit 9992795 "fix(lxmf):
            // prevent relay self-echo from overwriting outbound
            // messages", 2026-02-05) silenced these to keep the DB
            // record's `incoming` flag from being overwritten.
            //
            // The current narrowed form rejects only when the dest is
            // someone else (`destinationHash != localDeliveryHash`)
            // AND the method is non-propagated. Three legitimate
            // self-loop cases are intentionally allowed through:
            //
            //  1. PROPAGATION sync — we deliberately pulled this from
            //     the propagation node (`method == .propagated`).
            //  2. Self-send via DIRECT — link target is our own
            //     delivery destination; the inbound dest IS us.
            //  3. Self-send via OPPORTUNISTIC — same as #2 but single-
            //     packet. Also exercised by the iOS smoke harness
            //     (`opp_bidirectional`) and by multi-device-via-same-
            //     identity UX flows.
            //
            // The remaining rejection case — broadcast echo of an
            // outbound to someone else — is the bug case the original
            // 2026-02-05 fix targeted: source=us, destination=other,
            // method=direct/opp, packet bounced off the TCP relay back
            // into our inbound path. Those still get silenced.
            //
            // python ref: LXMF/LXMRouter.py has no self-echo gate;
            // duplicate-hash detection is the only mechanism. Documented
            // in port-deviations.md.
            let localDeliveryHash = Destination.hash(identity: identity, appName: "lxmf", aspects: ["delivery"])
            if sourceHash == localDeliveryHash
                && destinationHash != localDeliveryHash
                && method != .propagated {
                routerLogger.info("REJECTED: self-echo from \(srcHex) via \(String(describing: method))")
                return false
            }

            // Look up source identity from cache for signature validation
            let sourceIdentity = identityCache[sourceHash]
            routerLogger.info("source=\(srcHex), identityCached=\(sourceIdentity != nil)")

            // Unpack message from wire format, passing source identity if known
            var message = try LXMessage.unpackFromBytes(data, sourceIdentity: sourceIdentity)
            let msgHashHex = message.hash.prefix(4).map { String(format: "%02x", $0) }.joined()
            let fieldsDesc = message.fields?.keys.map { String(format: "0x%02x", $0) }.joined(separator: ",") ?? "nil"
            routerLogger.info("Unpacked: hash=\(msgHashHex) contentLen=\(message.content.count) fields=[\(fieldsDesc)] sigValid=\(message.signatureValidated) unverified=\(String(describing: message.unverifiedReason))")

            // Override the default method (which `unpackFromBytes` always sets to `.direct`)
            // with the actual delivery method observed by the caller. This matches Python
            // LXMRouter.lxmf_delivery(): `if method: message.method = method`.
            if let method = method {
                message.method = method
            }

            // Validate signature (silent drop if invalid, per Python behavior)
            // If source identity is unknown, accept but mark unverified
            if message.signatureValidated == false && message.unverifiedReason == .signatureInvalid {
                routerLogger.warning("REJECTED: invalid signature from \(srcHex)")
                return false
            }

            // Check duplicate (transient ID = message hash)
            if deliveredTransientIDs[message.hash] != nil {
                routerLogger.info("REJECTED: duplicate hash=\(msgHashHex)")
                return false
            }

            // Add to duplicate cache with current timestamp
            deliveredTransientIDs[message.hash] = Date()

            // Clean expired entries from duplicate cache
            cleanDuplicateCache()

            // Apply physical stats if provided
            if let stats = physicalStats {
                message.rssi = stats.rssi
                message.snr = stats.snr
                message.q = stats.q
                message.receivingInterface = stats.receivingInterface
            }

            // Mark as incoming
            message.incoming = true

            // Store in database and await completion so message is persisted
            // before the delegate callback triggers UI reload.
            do {
                try await database.saveMessage(message)
            } catch {
                routerLogger.error("Failed to persist message: \(error)")
            }

            // Invoke delegate callback on main actor
            let hasDelegate = delegateWrapper?.delegate != nil
            routerLogger.info("ACCEPTED: hash=\(msgHashHex) contentLen=\(message.content.count) fields=[\(fieldsDesc)] hasDelegate=\(hasDelegate)")
            if let wrapper = delegateWrapper, let delegate = wrapper.delegate {
                Task { @MainActor in
                    delegate.router(self, didReceiveMessage: message)
                }
            }

            return true

        } catch {
            // Invalid message format, signature failed, etc.
            // Python silently drops malformed messages
            routerLogger.error("REJECTED: unpack/validation error: \(error)")
            return false
        }
    }

    // MARK: - Outbound Processing

    /// Process outbound message queue.
    ///
    /// Iterates pending messages, attempts delivery based on method and state,
    /// moves to failed queue after MAX_DELIVERY_ATTEMPTS, and schedules next processing.
    ///
    /// IMPORTANT: Actual transport delivery (send packet, establish link) deferred to Plan 06-06.
    /// For now, this prepares messages but doesn't send.
    ///
    /// Reference: Python LXMRouter.process_outbound() lines 2496-2700
    public func processOutbound() async {
        // Don't process if shutdown
        guard !isShutdown else {
            return
        }

        // Guard against reentrant calls
        guard !processingOutbound else {
            return
        }
        processingOutbound = true
        defer { processingOutbound = false }

        // Track indices to remove (use index-based access so struct mutations persist)
        var indicesToRemove: IndexSet = []

        for i in pendingOutbound.indices {
            // Check if message already delivered
            if pendingOutbound[i].state == .delivered {
                indicesToRemove.insert(i)
                continue
            }

            // Check if message cancelled
            if pendingOutbound[i].state == .cancelled {
                indicesToRemove.insert(i)
                notifyFailure(pendingOutbound[i], reason: .invalidStateTransition(from: .outbound, to: .cancelled))
                continue
            }

            // Check if message has been pending too long (prevents crash loops from stuck messages)
            let messageAge = Date().timeIntervalSince1970 - pendingOutbound[i].timestamp
            if messageAge > Self.MAX_OUTBOUND_AGE {
                pendingOutbound[i].state = .failed
                let expiredMsg = pendingOutbound[i]
                indicesToRemove.insert(i)
                failedOutbound.append(expiredMsg)
                Task.detached { [database] in
                    try? await database.updateMessageState(id: expiredMsg.hash, state: .failed)
                }
                let destHex = expiredMsg.destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                routerLogger.warning("Message expired (age=\(Int(messageAge))s): dest=\(destHex)")
                notifyFailure(expiredMsg, reason: .maxAttemptsExceeded)
                continue
            }

            // Check if max delivery attempts exceeded
            if pendingOutbound[i].deliveryAttempts >= Self.MAX_DELIVERY_ATTEMPTS {
                pendingOutbound[i].state = .failed
                let failedMsg = pendingOutbound[i]
                indicesToRemove.insert(i)
                failedOutbound.append(failedMsg)

                // Update database
                Task.detached { [database] in
                    try? await database.updateMessageState(id: failedMsg.hash, state: .failed)
                }

                // Notify delegate
                notifyFailure(failedMsg, reason: .maxAttemptsExceeded)
                continue
            }

            // Check if should attempt delivery now
            let destHex = pendingOutbound[i].destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
            let shouldAttempt = shouldAttemptDelivery(pendingOutbound[i])
            if !shouldAttempt {
                continue
            }

            // Increment delivery attempts
            pendingOutbound[i].deliveryAttempts += 1

            // Attempt delivery based on method
            do {
                switch pendingOutbound[i].method {
                case .opportunistic:
                    // Opportunistic delivery: single packet via transport
                    let destHashHex = pendingOutbound[i].destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                    routerLogger.info("Processing opportunistic to \(destHashHex), attempts=\(self.pendingOutbound[i].deliveryAttempts)")

                    // Check if we need path and don't have one
                    let hasPathForOpp = await hasPath(pendingOutbound[i].destinationHash)

                    if pendingOutbound[i].deliveryAttempts >= Self.MAX_PATHLESS_TRIES, !hasPathForOpp {
                        // Request path and wait
                        requestPath(pendingOutbound[i].destinationHash)
                        pendingOutbound[i].nextDeliveryAttempt = Date().addingTimeInterval(Self.PATH_REQUEST_WAIT)
                    } else {
                        // Attempt send (copy out for inout async call, then write back)
                        routerLogger.debug("Calling sendOpportunistic for \(destHashHex)")
                        var msg = pendingOutbound[i]
                        try await sendOpportunistic(&msg)
                        pendingOutbound[i] = msg
                        routerLogger.info("sendOpportunistic completed for \(destHashHex)")
                        indicesToRemove.insert(i)

                        // Update database
                        let sentMsg = pendingOutbound[i]
                        Task.detached { [database] in
                            try? await database.updateMessageState(id: sentMsg.hash, state: .sent)
                        }
                    }

                case .direct:
                    // Direct delivery: over link
                    let destHashHex = pendingOutbound[i].destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                    let hasPathToRecipient = await hasPath(pendingOutbound[i].destinationHash)
                    let attempt = pendingOutbound[i].deliveryAttempts
                    routerLogger.info("Direct delivery: dest=\(destHashHex), hasPath=\(hasPathToRecipient), attempt=\(attempt)")
                    routerLogger.debug("Checking path to \(destHashHex), hasPath=\(hasPathToRecipient)")
                    if hasPathToRecipient {
                        // Attempt link-based send (copy out for inout async call)
                        routerLogger.info("Starting sendDirect to \(destHashHex)")
                        var msg = pendingOutbound[i]
                        try await sendDirect(&msg)
                        pendingOutbound[i] = msg
                        routerLogger.info("sendDirect completed to \(destHashHex)")
                        indicesToRemove.insert(i)

                        // Update database
                        let sentMsg = pendingOutbound[i]
                        Task.detached { [database] in
                            try? await database.updateMessageState(id: sentMsg.hash, state: .sent)
                        }
                    } else {
                        // Need path first
                        routerLogger.warning("No path to \(destHashHex), requesting path")
                        routerLogger.debug("No path to \(destHashHex), requesting path")
                        requestPath(pendingOutbound[i].destinationHash)
                        pendingOutbound[i].nextDeliveryAttempt = Date().addingTimeInterval(Self.PATH_REQUEST_WAIT)
                    }

                case .propagated:
                    let destHashHex = pendingOutbound[i].destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()

                    guard let nodeHash = outboundPropagationNode else {
                        // Propagation node not yet configured - don't count as attempt, retry soon
                        pendingOutbound[i].deliveryAttempts -= 1  // Undo increment
                        pendingOutbound[i].nextDeliveryAttempt = Date().addingTimeInterval(3)
                        break
                    }

                    let hasPathToNode = await hasPath(nodeHash)

                    if hasPathToNode {
                        var msg = pendingOutbound[i]
                        try await sendPropagated(&msg)
                        pendingOutbound[i] = msg
                        indicesToRemove.insert(i)

                        // Mirror python LXMRouter.py:2675-2728 +
                        // LXMessage.send() (LXMessage.py:498-512):
                        // PROPAGATED+RESOURCE leaves message.state =
                        // .sending in memory until the resource-
                        // completion callback (handlePropagationAccepted
                        // / handleOutboundResourceFailed) fires when
                        // RESOURCE_PRF or a resource-conclusion is
                        // received. Persisting `.sent` unconditionally
                        // here would lie to consumers (background
                        // fetch, app re-launch) about a message whose
                        // upload may still fail — they would skip the
                        // retry and the message would be silently
                        // stuck.
                        //
                        // The small-packet branch of sendPropagated
                        // (LXMRouter+Propagation.swift:202-207) DOES
                        // await proof inline before returning and
                        // sets message.state = .sent there, so only
                        // for the resource path is the in-memory
                        // state still .sending at this point.
                        //
                        // DB-persistence policy for the resource path:
                        // we deliberately do NOT persist `.sending` to
                        // the DB. `loadPendingOutbound()` filters
                        // strictly on `state == .outbound`
                        // (LXMFDatabase.swift:459-468), so a `.sending`
                        // row is invisible to the restart queue and a
                        // crash during the in-flight window (this
                        // detached write → resource callback) would
                        // permanently strand the message.
                        //
                        // Instead we persist a full message record
                        // with state `.outbound` (safe fallback —
                        // restart-recoverable) and the CURRENT
                        // `deliveryAttempts` count. The in-flight
                        // callbacks (handlePropagationAccepted,
                        // handleOutboundResourceFailed) overwrite this
                        // with the real terminal state when they fire.
                        // Using `saveMessage` (full record) rather
                        // than `updateMessageState` (state column
                        // only) is load-bearing — without persisting
                        // `deliveryAttempts`, a resource-failure
                        // re-enqueue via `handleOutboundResourceFailed`
                        // would reload `deliveryAttempts = 0` from the
                        // DB and effectively grant unlimited retries,
                        // bypassing `MAX_DELIVERY_ATTEMPTS`.
                        var snapshot = pendingOutbound[i]
                        snapshot.state = .outbound
                        Task.detached { [database] in
                            try? await database.saveMessage(snapshot)
                        }
                    } else {
                        requestPath(nodeHash)
                        pendingOutbound[i].nextDeliveryAttempt = Date().addingTimeInterval(Self.PATH_REQUEST_WAIT)
                    }

                default:
                    // Unknown method, skip
                    break
                }
            } catch {
                // Delivery failed, will retry on next cycle
                // Schedule retry with exponential backoff
                let backoffSeconds = min(Double(pendingOutbound[i].deliveryAttempts) * Self.PATH_REQUEST_WAIT, 300.0)
                pendingOutbound[i].nextDeliveryAttempt = Date().addingTimeInterval(backoffSeconds)
                let destHex = pendingOutbound[i].destinationHash.prefix(8).map { String(format: "%02x", $0) }.joined()
                routerLogger.error("Delivery failed for \(destHex): \(error.localizedDescription), retrying in \(backoffSeconds)s")
            }
        }

        // Remove sent/completed messages from pending (reverse order to preserve indices)
        for i in indicesToRemove.sorted().reversed() {
            pendingOutbound.remove(at: i)
        }

        // Persist state changes
        await persistPendingState()

        // Schedule next processing cycle (unless shutdown)
        if !isShutdown {
            Task {
                try? await Task.sleep(for: .seconds(Self.PROCESSING_INTERVAL))
                await processOutbound()
            }
        }
    }

    // MARK: - Utility Methods

    /// Clean expired entries from duplicate detection cache.
    ///
    /// Removes entries older than DUPLICATE_CACHE_EXPIRY (1 hour).
    private func cleanDuplicateCache() {
        let now = Date()
        let expiry = Self.DUPLICATE_CACHE_EXPIRY

        deliveredTransientIDs = deliveredTransientIDs.filter { (_, timestamp) in
            now.timeIntervalSince(timestamp) < expiry
        }
    }

    /// Notify delegate of message failure.
    ///
    /// - Parameters:
    ///   - message: Failed message
    ///   - reason: Error causing failure
    /// `internal` (was `private`) so cross-file extensions in this module
    /// can fire delegate failure callbacks. Specifically
    /// `LXMRouter+Propagation`'s ERROR_INVALID_STAMP signal handler needs
    /// to notify the delegate when the propagation node rejects a stamp.
    internal func notifyFailure(_ message: LXMessage, reason: LXMFError) {
        if let wrapper = delegateWrapper, let delegate = wrapper.delegate {
            Task { @MainActor in
                delegate.router(self, didFailMessage: message, reason: reason)
            }
        }
    }

    /// Notify delegate of message state update.
    ///
    /// - Parameter message: Message with updated state
    public func notifyUpdate(_ message: LXMessage) {
        if let wrapper = delegateWrapper, let delegate = wrapper.delegate {
            Task { @MainActor in
                delegate.router(self, didUpdateMessage: message)
            }
        }
    }

    // MARK: - Delivery Proof Handling

    /// Handle delivery proof received for a sent message.
    ///
    /// Updates the message state to `.delivered` in the database and notifies
    /// the delegate to trigger UI refresh (single checkmark → double checkmark).
    ///
    /// - Parameter messageHash: The LXMF message hash (32 bytes)
    public func handleDeliveryProofReceived(messageHash: Data) {
        let hashHex = messageHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.error("Delivery proof received for message \(hashHex, privacy: .public)")

        // Update database state to delivered
        Task.detached { [database] in
            try? await database.updateMessageState(id: messageHash, state: .delivered)
        }

        // Notify delegate for UI refresh
        if let wrapper = delegateWrapper, let delegate = wrapper.delegate {
            let hash = messageHash
            Task { @MainActor in
                delegate.router(self, didConfirmDelivery: hash)
            }
        }
    }

    /// Handle outbound resource transfer completion (RESOURCE_PRF received).
    ///
    /// Called by `LXMFOutboundResourceHandler` when a resource proof is
    /// received. Looks up the corresponding message hash and routes to
    /// the right terminal-state handler based on whether the resource
    /// was a DIRECT delivery (state advances to `.delivered`) or a
    /// PROPAGATED upload (state advances to `.sent` only — propagation
    /// nodes ack the upload, not the recipient's receipt).
    ///
    /// Mirrors python `LXMessage.__as_resource` (LXMF/LXMessage.py:635-
    /// 651) which wires DIFFERENT resource callbacks per method:
    ///   - DIRECT path: `RNS.Resource(packed, destination,
    ///     callback=self.__resource_concluded, ...)` → on COMPLETE
    ///     `__mark_delivered` (LXMessage.py:556-566) → state=DELIVERED.
    ///   - PROPAGATED path: `RNS.Resource(propagation_packed, link,
    ///     callback=self.__propagation_resource_concluded, ...)` → on
    ///     COMPLETE `__mark_propagated` (LXMessage.py:568-578) →
    ///     state=SENT.
    ///
    /// Without this distinction, large PROPAGATED messages (which use
    /// Resource transfer because they exceed `LINK_PACKET_MDU` = 431
    /// bytes) incorrectly advance to DELIVERED in the iOS UI, claiming
    /// the recipient acked delivery — but the sender NEVER learns when
    /// the recipient syncs the message down from the propagation node.
    /// Tyler observed this as "PROPAGATED messages show double
    /// checkmark" on the iOS UI 2026-05-10.
    ///
    /// - Parameter resourceHash: The 32-byte resource hash
    public func handleResourceTransferComplete(resourceHash: Data) {
        let resHex = resourceHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        guard let messageHash = pendingResourceDeliveries.removeValue(forKey: resourceHash) else {
            routerLogger.info("Resource \(resHex, privacy: .public) completed but no pending message mapping")
            return
        }
        let msgHex = messageHash.prefix(8).map { String(format: "%02x", $0) }.joined()

        if pendingPropagationResources.remove(resourceHash) != nil {
            // PROPAGATED resource transfer — python `__mark_propagated`.
            routerLogger.info("Resource \(resHex, privacy: .public) → message \(msgHex, privacy: .public), marking sent (propagation node ack)")
            handlePropagationAccepted(messageHash: messageHash)
        } else {
            // DIRECT resource transfer — python `__mark_delivered`.
            routerLogger.info("Resource \(resHex, privacy: .public) → message \(msgHex, privacy: .public), marking delivered (recipient ack)")
            handleDeliveryProofReceived(messageHash: messageHash)
        }
    }

    /// Handle outbound resource transfer FAILURE (resource concluded
    /// in any non-`.complete` state — `.failed`, `.rejected`,
    /// `.cancelled`, etc.).
    ///
    /// Mirrors python `LXMessage.__resource_concluded`
    /// (LXMF/LXMessage.py:592-601) for the DIRECT path and
    /// `__propagation_resource_concluded` (LXMessage.py:603-609) for
    /// the PROPAGATED path. Critical responsibilities:
    ///
    ///   1. Reclaim the swift-port-introduced map state
    ///      (`pendingResourceDeliveries`, `pendingPropagationResources`).
    ///      Python uses LXMessage object lifetime instead and has
    ///      nothing to clean up; we externalized the tracking so we
    ///      now have lifetime obligations python doesn't.
    ///   2. Advance message state per python's per-method semantics:
    ///      - DIRECT, resource state == .rejected → state = `.rejected`
    ///        (python `LXMessage.py:597` sets `state = REJECTED`).
    ///      - DIRECT, other non-complete (and not cancelled) →
    ///        state = `.outbound` for retry (python
    ///        `LXMessage.py:598-601` tears down the link + sets
    ///        `state = OUTBOUND`). We skip the explicit teardown
    ///        because reticulum-swift's link layer detects the
    ///        failed transfer separately; if a follow-up bug shows
    ///        the link sticks around in a bad state across retries,
    ///        re-add `await resource.link?.close(reason: .timeout)`.
    ///      - PROPAGATED, any non-complete (and not cancelled) →
    ///        state = `.outbound` (python `LXMessage.py:607-609`
    ///        does not distinguish REJECTED from other failures on
    ///        the propagation path; everything retries via the
    ///        outbound queue).
    ///
    /// Without this method, `resourceConcluded` returned early on
    /// non-complete states and the maps grew without bound across the
    /// router's lifetime; if the same resource hash were ever to
    /// re-complete (highly unlikely but not impossible), the wrong
    /// per-method state handler would fire.
    ///
    /// - Parameters:
    ///   - resourceHash: 32-byte resource hash from the failed transfer.
    ///   - resourceState: Terminal `ResourceState` reported by reticulum-swift.
    public func handleOutboundResourceFailed(
        resourceHash: Data, resourceState: ResourceState
    ) async {
        let resHex = resourceHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        let wasPropagation = pendingPropagationResources.remove(resourceHash) != nil
        guard let messageHash = pendingResourceDeliveries.removeValue(forKey: resourceHash) else {
            routerLogger.info("Outbound resource \(resHex, privacy: .public) failed (\(String(describing: resourceState))) but no pending message mapping; entries reclaimed (none found)")
            return
        }
        let msgHex = messageHash.prefix(8).map { String(format: "%02x", $0) }.joined()

        // Compute the new LXMessage state per python's per-method
        // semantics. Python `LXMessage.py:592-609` guards the retry
        // path with `if self.state != CANCELLED` on BOTH the DIRECT
        // (`__resource_concluded`, line 598) and PROPAGATED
        // (`__propagation_resource_concluded`, line 607) paths —
        // meaning `.cancelled` is terminal and the message is NOT
        // re-queued for retry. The DIRECT path additionally treats
        // `RNS.Resource.REJECTED` as a distinct terminal state
        // (LXMessage.py:597). Greptile review (4/5 confidence)
        // flagged the earlier swift port for retrying on `.cancelled`,
        // which would silently burn the retry budget on a
        // peer-cancelled transfer.
        let newState: LXMessageState
        let isTerminal: Bool
        if resourceState == .cancelled {
            // Python: state stays whatever the sender already set it
            // to (typically CANCELLED if the sender cancelled, or some
            // other state if peer cancelled mid-transfer). Persist
            // `.cancelled` so the DB reflects the terminal outcome.
            newState = .cancelled
            isTerminal = true
            routerLogger.info("Outbound resource \(resHex, privacy: .public) → message \(msgHex, privacy: .public) cancelled; terminal (no retry per python LXMessage.py:598/607)")
        } else if wasPropagation {
            // Python LXMessage.py:607-609: any non-complete (and not
            // cancelled, handled above) → state=OUTBOUND for retry.
            newState = .outbound
            isTerminal = false
            routerLogger.info("Outbound PROPAGATED resource \(resHex, privacy: .public) → message \(msgHex, privacy: .public) failed (\(String(describing: resourceState))); marking outbound for retry")
        } else {
            // Python LXMessage.py:596-601 (DIRECT): REJECTED is its
            // own terminal state; everything else (and not cancelled,
            // handled above) gets OUTBOUND for retry.
            if resourceState == .rejected {
                newState = .rejected
                isTerminal = true
            } else {
                newState = .outbound
                isTerminal = false
            }
            routerLogger.info("Outbound DIRECT resource \(resHex, privacy: .public) → message \(msgHex, privacy: .public) failed (\(String(describing: resourceState))); → \(String(describing: newState))")
        }

        // Persist the new state synchronously here so the in-memory
        // re-enqueue below (if applicable) can read back a consistent
        // record. Errors are non-fatal — the in-memory state on the
        // re-enqueued LXMessage is the authoritative driver for the
        // next `processOutbound` tick; DB persistence is for
        // cross-launch durability and any retry on app re-launch.
        do {
            try await database.updateMessageState(id: messageHash, state: newState)
        } catch {
            routerLogger.error("Failed to persist failed-resource state for \(msgHex, privacy: .public): \(error)")
        }

        // Re-enqueue retryable failures into `pendingOutbound`.
        //
        // Without this step, `processOutbound` had already removed the
        // message from the in-memory queue via `indicesToRemove`
        // (LXMRouter.swift:~660) BEFORE the resource conclusion
        // callback fires — there's no periodic DB→queue reload, so a
        // failed resource transfer would silently disappear from the
        // retry queue until the next app launch.
        //
        // For `.outbound`-bound retries we reload the LXMessage from
        // the DB (it has the freshly-written `.outbound` state and
        // the original packed payload), bump `deliveryAttempts` +
        // `nextDeliveryAttempt` so the next `processOutbound` tick
        // doesn't immediately re-fire and burn the retry budget, then
        // append + kick processing.
        //
        // Terminal states (`.rejected` for DIRECT, `.cancelled` for
        // either path) skip the re-enqueue — python treats both as
        // end-of-line. The DB row stays with the terminal state for
        // the UI to render (and for any background-fetch / app-
        // re-launch consumer to see).
        guard !isTerminal else {
            routerLogger.debug("\(msgHex, privacy: .public) is terminal (\(String(describing: newState))); skipping re-enqueue")
            return
        }

        do {
            guard var msg = try await database.getMessage(id: messageHash) else {
                routerLogger.warning("Cannot re-enqueue \(msgHex, privacy: .public): DB lookup returned nil")
                return
            }
            // State is .outbound (already persisted above). Don't bump
            // `deliveryAttempts` here — `processOutbound` increments it
            // at line ~584 when it actually attempts delivery. Bumping
            // here too would double-count and hit MAX_DELIVERY_ATTEMPTS
            // (=8) in half the expected cycles.
            //
            // MAX_DELIVERY_ATTEMPTS budget integrity: the persisted
            // `deliveryAttempts` we just reloaded reflects the in-flight
            // attempt that just failed, because `processOutbound`'s
            // PROPAGATED+RESOURCE branch now `saveMessage`s the full
            // record (with the post-increment count) before scheduling
            // the resource transfer. Without that full-record write the
            // reload would see `deliveryAttempts = 0` and effectively
            // grant unlimited retries per resource failure. See
            // `port-deviations.md` (sub-deviation under "processOutbound
            // optimistic queue removal").
            //
            // Backoff via `nextDeliveryAttempt` ensures the re-enqueued
            // message doesn't immediately retry on the next
            // `processOutbound` tick. Mirrors python
            // `LXMRouter.py:2638/2645/2700` which schedules the next
            // attempt at `time.time() + PATH_REQUEST_WAIT` (flat — no
            // per-attempt scaling). `processOutbound`'s catch-block
            // backoff at line ~699 (which DOES scale per attempt) does
            // not fire for callback-arrived resource failures because
            // `sendPropagated` already returned successfully and the
            // failure is reported asynchronously via the resource
            // callback path — that scaling is therefore not load-
            // bearing for this code path. If persistent resource
            // failures need wider spacing in future, both this site
            // and the catch-block scaling should be re-aligned
            // together (and a unified deviation note added).
            msg.state = .outbound
            msg.nextDeliveryAttempt = Date().addingTimeInterval(Self.PATH_REQUEST_WAIT)
            pendingOutbound.append(msg)
            routerLogger.info("\(msgHex, privacy: .public) re-enqueued for retry (attempts so far: \(msg.deliveryAttempts), next attempt in \(Int(Self.PATH_REQUEST_WAIT))s)")
        } catch {
            routerLogger.error("Failed to re-enqueue \(msgHex, privacy: .public): \(error)")
            return
        }

        // Kick the processing loop so the re-enqueued message is
        // considered on the next iteration without waiting for a
        // periodic tick. Detached so we don't extend this
        // delegate-callback path's lifetime.
        Task.detached { [weak self] in
            await self?.processOutbound()
        }
    }

    /// Handle propagation-upload acceptance (RESOURCE_PRF from
    /// propagation node received, OR small-packet PROOF from
    /// propagation node received).
    ///
    /// Mirrors python `LXMessage.__mark_propagated` (LXMF/LXMessage.py
    /// :568-578) which sets `state = SENT, progress = 1.0` and fires
    /// the user's delivery callback. The user's callback is shared
    /// between direct and propagated paths in python — the SENT vs
    /// DELIVERED state distinction is what consumers (UI, etc.) read.
    ///
    /// - Parameter messageHash: The LXMF message hash (32 bytes)
    public func handlePropagationAccepted(messageHash: Data) {
        let hashHex = messageHash.prefix(8).map { String(format: "%02x", $0) }.joined()
        routerLogger.info("Propagation upload accepted for message \(hashHex, privacy: .public)")

        // Update database state to sent (NOT delivered — see comment on
        // handleResourceTransferComplete + python LXMessage.py:568-578).
        Task.detached { [database] in
            try? await database.updateMessageState(id: messageHash, state: .sent)
        }

        // Notify delegate. We reuse `didConfirmDelivery` for the UI
        // refresh signal — the delegate's job is "this message's state
        // changed, reload it"; reading the new state is the consumer's
        // responsibility. Adding a separate `didConfirmPropagation`
        // delegate method would be a larger API change for no
        // additional information (consumers already read `.state` on
        // the reloaded message).
        if let wrapper = delegateWrapper, let delegate = wrapper.delegate {
            let hash = messageHash
            Task { @MainActor in
                delegate.router(self, didConfirmDelivery: hash)
            }
        }
    }

    // MARK: - Path Management

    /// Check if path exists for destination.
    ///
    /// - Parameter destinationHash: 16-byte destination hash
    /// - Returns: True if valid path exists
    public func hasPath(_ destinationHash: Data) async -> Bool {
        guard let pathTable = pathTable else { return false }
        return await pathTable.hasPath(for: destinationHash)
    }

    /// Request path for destination.
    ///
    /// - Parameter destinationHash: 16-byte destination hash
    public func requestPath(_ destinationHash: Data) {
        guard let transport = transport else { return }
        Task {
            await transport.requestPath(for: destinationHash)
        }
    }

    /// Persist pending message state to database.
    ///
    /// Batches all saves into a single detached Task to avoid memory accumulation
    /// from N captured message copies (important for large image messages).
    public func persistPendingState() async {
        guard !pendingOutbound.isEmpty else { return }
        let messages = pendingOutbound  // Single copy of the array
        Task.detached { [database] in
            for message in messages {
                try? await database.saveMessage(message)
            }
        }
    }

    /// Check if delivery should be attempted for message.
    ///
    /// - Parameter message: Message to check
    /// - Returns: True if should attempt delivery now
    private func shouldAttemptDelivery(_ message: LXMessage) -> Bool {
        // Check if next attempt time has passed
        if let nextAttempt = message.nextDeliveryAttempt {
            return Date() >= nextAttempt
        }
        // If no next attempt time set, attempt now
        return true
    }
}

// MARK: - Physical Stats

/// Physical layer statistics for received messages.
///
/// Provides signal quality metrics from the physical transport layer.
public struct PhysicalStats: Sendable {
    /// Received Signal Strength Indicator (dBm)
    public var rssi: Double?

    /// Signal-to-Noise Ratio (dB)
    public var snr: Double?

    /// Link quality indicator (0.0 to 1.0)
    public var q: Double?

    /// Human-readable name of the interface that received this message
    public var receivingInterface: String?

    public init(rssi: Double? = nil, snr: Double? = nil, q: Double? = nil, receivingInterface: String? = nil) {
        self.rssi = rssi
        self.snr = snr
        self.q = q
        self.receivingInterface = receivingInterface
    }
}
