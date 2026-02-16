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

private let routerLogger = Logger(subsystem: "com.columba.app", category: "LXMRouter")

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

    // MARK: - Properties

    /// Local identity for signing outbound messages
    public let identity: Identity

    /// Database for message persistence
    private let database: LXMFDatabase

    /// In-memory pending outbound queue (PRIMARY)
    private var pendingOutbound: [LXMessage] = []

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
    public var transport: ReticuLumTransport?

    /// Path table for route lookup (accessed via transport)
    public var pathTable: PathTable?

    /// Active and pending links for direct delivery
    public var deliveryLinks: [Data: Link] = [:]

    /// Active propagation links (separate cache from delivery links)
    public var propagationLinks: [Data: Link] = [:]

    /// Outbound propagation node hash (16 bytes).
    /// When set, .propagated delivery sends messages to this node.
    public var outboundPropagationNode: Data?

    /// Stamp cost required by the selected propagation node.
    /// Set when selecting a propagation node (from PropagationNodeInfo.stampCost).
    /// 0 = no stamp work required (any 32-byte stamp accepted).
    public var propagationStampCost: Int = 0

    /// Current sync state for UI observation.
    public var syncState = PropagationTransferState()

    /// Registered delivery destinations
    public var deliveryDestinations: [Data: (Destination, Int?)] = [:]

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
        let pending = try await database.loadPendingOutbound()
        self.pendingOutbound = pending

        // Load failed outbound from database
        let failed = try await database.loadFailedOutbound()
        self.failedOutbound = failed

        // Start the outbound processing loop if there are pending messages
        if !pending.isEmpty {
            print("[LXMF_ROUTER] Starting outbound processor with \(pending.count) pending messages")
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
    /// - Parameter transport: ReticuLumTransport instance for sending packets
    public func setTransport(_ transport: ReticuLumTransport) async {
        self.transport = transport
        // Access path table from transport for route lookups
        self.pathTable = await transport.getPathTable()
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
                routerLogger.info("[OUTBOUND] Message too large for opportunistic (\(packedPayloadSize) > \(LXMFConstants.ENCRYPTED_PACKET_MAX_CONTENT)), falling back to \(String(describing: fallback))")
                print("[LXMF] Message too large for opportunistic (\(packedPayloadSize) > \(LXMFConstants.ENCRYPTED_PACKET_MAX_CONTENT)), falling back to \(fallback)")
                message.method = fallback
            } else {
                routerLogger.info("[OUTBOUND] Message fits in opportunistic: \(packedPayloadSize) bytes")
            }
        }

        // Add to pending outbound queue
        pendingOutbound.append(message)

        // Persist to database (async, non-blocking)
        Task.detached { [database, message] in
            try? await database.saveMessage(message)
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
    /// - Returns: True if message was accepted, false if rejected (duplicate, invalid signature, etc.)
    ///
    /// Reference: Python LXMRouter.lxmf_delivery() lines 1714-1799
    @discardableResult
    public func lxmfDelivery(_ data: Data, physicalStats: PhysicalStats? = nil) async -> Bool {
        let dataHex = data.prefix(32).map { String(format: "%02x", $0) }.joined()
        print("[LXMF_INBOUND] lxmfDelivery called: \(data.count) bytes, data[0:32]=\(dataHex)")

        do {
            // Extract source hash to look up identity for signature validation
            // LXMF format: [dest_hash 16B][src_hash 16B][signature 64B][payload...]
            guard data.count >= 32 else {
                print("[LXMF_INBOUND] Message too short (<32 bytes), rejecting")
                return false  // Invalid message
            }
            let sourceHash = data.subdata(in: 16..<32)
            let sourceHashHex = sourceHash.prefix(8).map { String(format: "%02x", $0) }.joined()
            print("[LXMF_INBOUND] sourceHash=\(sourceHashHex)")

            // Self-echo detection: relay broadcasts our own outbound messages back to us.
            // Skip any message whose source is our own LXMF delivery destination hash.
            let localDeliveryHash = Destination.hash(identity: identity, appName: "lxmf", aspects: ["delivery"])
            if sourceHash == localDeliveryHash {
                print("[LXMF_INBOUND] Self-echo detected (sourceHash matches local delivery hash), ignoring")
                return false
            }

            // Look up source identity from cache for signature validation
            let sourceIdentity = identityCache[sourceHash]
            print("[LXMF_INBOUND] sourceIdentity from cache: \(sourceIdentity != nil ? "FOUND" : "NOT FOUND")")

            // Unpack message from wire format, passing source identity if known
            print("[LXMF_INBOUND] Calling LXMessage.unpackFromBytes()...")
            var message = try LXMessage.unpackFromBytes(data, sourceIdentity: sourceIdentity)
            print("[LXMF_INBOUND] Unpacked message: hash=\(message.hash.prefix(8).map { String(format: "%02x", $0) }.joined()), content len=\(message.content.count)")

            // Validate signature (silent drop if invalid)
            // Python silently drops invalid signatures to prevent DOS
            // NOTE: If source identity is unknown, we can't validate signature - accept but mark unverified
            // Only reject if signature was actually validated and failed
            if message.signatureValidated == false && message.unverifiedReason == .signatureInvalid {
                // Signature validation was attempted and failed
                print("[LXMF_INBOUND] Signature validation FAILED, rejecting")
                return false
            }
            print("[LXMF_INBOUND] Signature check passed (validated=\(message.signatureValidated), reason=\(String(describing: message.unverifiedReason)))")

            // Check duplicate (transient ID = message hash)
            if let cachedTime = deliveredTransientIDs[message.hash] {
                // Already delivered, ignore
                print("[LXMF_INBOUND] Duplicate message detected (cached at \(cachedTime)), rejecting")
                return false
            }
            print("[LXMF_INBOUND] Not a duplicate, proceeding")

            // TODO: Validate stamp if required (deferred to stamping integration)
            // For now, accept all messages without stamp validation

            // Add to duplicate cache with current timestamp
            deliveredTransientIDs[message.hash] = Date()

            // Clean expired entries from duplicate cache
            cleanDuplicateCache()

            // Apply physical stats if provided
            if let stats = physicalStats {
                message.rssi = stats.rssi
                message.snr = stats.snr
                message.q = stats.q
            }

            // Mark as incoming
            message.incoming = true

            // Store in database and await completion so message is persisted
            // before the delegate callback triggers UI reload.
            // Previously used Task.detached (fire-and-forget) which raced with
            // the delegate's own DB writes, causing "database is locked" errors.
            do {
                try await database.saveMessage(message)
            } catch {
                print("[LXMF_INBOUND] Failed to persist message: \(error)")
            }

            // Invoke delegate callback on main actor
            print("[LXMF_INBOUND] Checking for delegate: wrapper=\(delegateWrapper != nil), delegate=\(delegateWrapper?.delegate != nil)")
            if let wrapper = delegateWrapper, let delegate = wrapper.delegate {
                print("[LXMF_INBOUND] Invoking delegate.router(didReceiveMessage:) on main actor")
                Task { @MainActor in
                    delegate.router(self, didReceiveMessage: message)
                }
            } else {
                print("[LXMF_INBOUND] NO DELEGATE SET - message will not be delivered to app!")
            }

            print("[LXMF_INBOUND] Message accepted successfully")
            return true

        } catch {
            // Invalid message format, signature failed, etc.
            // Python silently drops malformed messages
            print("[LXMF_INBOUND] Exception during processing: \(error)")
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
                    print("[LXMF_OPP] Processing opportunistic to \(destHashHex), attempts=\(pendingOutbound[i].deliveryAttempts)")

                    // Check if we need path and don't have one
                    let hasPathForOpp = await hasPath(pendingOutbound[i].destinationHash)

                    if pendingOutbound[i].deliveryAttempts >= Self.MAX_PATHLESS_TRIES, !hasPathForOpp {
                        // Request path and wait
                        requestPath(pendingOutbound[i].destinationHash)
                        pendingOutbound[i].nextDeliveryAttempt = Date().addingTimeInterval(Self.PATH_REQUEST_WAIT)
                    } else {
                        // Attempt send (copy out for inout async call, then write back)
                        print("[LXMF_OPP] Calling sendOpportunistic for \(destHashHex)")
                        var msg = pendingOutbound[i]
                        try await sendOpportunistic(&msg)
                        pendingOutbound[i] = msg
                        print("[LXMF_OPP] sendOpportunistic completed for \(destHashHex)")
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
                    routerLogger.info("[PROCESS] Direct delivery: dest=\(destHashHex), hasPath=\(hasPathToRecipient), attempt=\(attempt)")
                    print("[LXMF_DIRECT] Checking path to \(destHashHex), hasPath=\(hasPathToRecipient)")
                    if hasPathToRecipient {
                        // Attempt link-based send (copy out for inout async call)
                        routerLogger.info("[PROCESS] Starting sendDirect to \(destHashHex)")
                        var msg = pendingOutbound[i]
                        try await sendDirect(&msg)
                        pendingOutbound[i] = msg
                        routerLogger.info("[PROCESS] sendDirect completed to \(destHashHex)")
                        indicesToRemove.insert(i)

                        // Update database
                        let sentMsg = pendingOutbound[i]
                        Task.detached { [database] in
                            try? await database.updateMessageState(id: sentMsg.hash, state: .sent)
                        }
                    } else {
                        // Need path first
                        routerLogger.warning("[PROCESS] No path to \(destHashHex), requesting path")
                        print("[LXMF_DIRECT] No path to \(destHashHex), requesting path")
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

                        let sentMsg = pendingOutbound[i]
                        Task.detached { [database] in
                            try? await database.updateMessageState(id: sentMsg.hash, state: .sent)
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
                routerLogger.error("[PROCESS] Delivery failed for \(destHex): \(error.localizedDescription), retrying in \(backoffSeconds)s")
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
    private func notifyFailure(_ message: LXMessage, reason: LXMFError) {
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
    public func persistPendingState() async {
        for message in pendingOutbound {
            Task.detached { [database, message] in
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

    public init(rssi: Double? = nil, snr: Double? = nil, q: Double? = nil) {
        self.rssi = rssi
        self.snr = snr
        self.q = q
    }
}
