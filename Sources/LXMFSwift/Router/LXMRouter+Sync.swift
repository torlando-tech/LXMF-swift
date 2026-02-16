//
//  LXMRouter+Sync.swift
//  LXMFSwift
//
//  3-step sync protocol for retrieving messages from a propagation node.
//  Step 1 (LIST): Get list of transient IDs from node
//  Step 2 (WANT/HAVE): Request messages we don't have, tell node what we have
//  Step 3 (ACK): Tell node to delete messages we received
//
//  Reference: LXMF/LXMRouter.py propagation sync logic
//

import Foundation
import ReticulumSwift
import os.log

private let syncLogger = Logger(subsystem: "com.columba.core", category: "Sync")

extension LXMRouter {

    // MARK: - Sync from Propagation Node

    /// Sync messages from the configured propagation node.
    ///
    /// Implements the 3-step sync protocol:
    /// 1. **LIST**: Request list of transient IDs available on node
    /// 2. **WANT/HAVE**: Send lists of wanted and already-have IDs, receive message data
    /// 3. **ACK**: Acknowledge received messages so node can delete them
    ///
    /// Propagated messages are encrypted at the LXMF layer (Python LXMRouter.py lines 434-438).
    /// Format: `dest_hash(16) + encrypt(source_hash + signature + packed_payload)`.
    /// The server strips the stamp before sending (line 1492).
    /// We decrypt each message using our identity before passing to `lxmfDelivery()`.
    ///
    /// - Throws: LXMFError if propagation node not set, link fails, or sync fails
    public func syncFromPropagationNode() async throws {
        guard let propagationNode = outboundPropagationNode else {
            syncLogger.error("[SYNC] No outboundPropagationNode set")
            syncState.state = .noPath
            syncState.errorDescription = "No propagation node configured"
            throw LXMFError.propagationNodeNotSet
        }

        guard let transport = self.transport else {
            syncLogger.error("[SYNC] Transport not available")
            syncState.state = .linkFailed
            syncState.errorDescription = "Transport not available"
            throw LXMFError.transportNotAvailable
        }

        // Update state machine
        syncState = PropagationTransferState()
        syncState.state = .linkEstablishing
        notifySyncStateUpdate()

        let nodeHex = propagationNode.prefix(8).map { String(format: "%02x", $0) }.joined()
        syncLogger.info("[SYNC] Establishing link to \(nodeHex)")

        // Establish link to propagation node
        let link: Link
        do {
            link = try await getOrEstablishPropagationLink(to: propagationNode, transport: transport)
            syncState.state = .linkEstablished
            notifySyncStateUpdate()
        } catch {
            syncLogger.error("[SYNC] Link failed to \(nodeHex): \(error)")
            syncState.state = .linkFailed
            syncState.errorDescription = error.localizedDescription
            notifySyncStateUpdate()
            throw error
        }

        // Identify ourselves
        do {
            try await link.identify(identity: identity)
        } catch {
            syncLogger.warning("[SYNC] Link identify failed (non-fatal): \(error)")
        }

        // Step 1: LIST - get transient IDs from node
        syncState.state = .requestSent
        notifySyncStateUpdate()

        let listReceipt: RequestReceipt
        do {
            listReceipt = try await link.request(
                path: PropagationConstants.SYNC_PATH,
                data: .array([.null, .null]),
                timeout: PropagationConstants.SYNC_TIMEOUT
            )
        } catch {
            syncLogger.error("[SYNC] LIST request failed: \(error)")
            syncState.state = .transferFailed
            syncState.errorDescription = "List request failed: \(error.localizedDescription)"
            notifySyncStateUpdate()
            throw LXMFError.syncFailed("List request failed: \(error.localizedDescription)")
        }

        // Wait for LIST response
        let listResponse = try await waitForRequestResponse(listReceipt)
        let transientIds = parseTransientIdList(listResponse)
        syncLogger.info("[SYNC] LIST: \(transientIds.count) messages on node")

        if transientIds.isEmpty {
            syncState.state = .complete
            syncState.lastSync = Date()
            notifySyncStateUpdate()
            notifySyncCompletion(newMessageCount: 0)
            return
        }

        syncState.totalMessages = transientIds.count
        syncState.state = .receiving
        notifySyncStateUpdate()

        // Filter out messages we already have
        let wantIds = filterTransientIds(transientIds)
        let haveIds = transientIds.filter { !wantIds.contains($0) }

        if wantIds.isEmpty {
            // We have all messages already, just ACK
            try await sendSyncAck(link: link, ackIds: transientIds)
            syncState.state = .complete
            syncState.lastSync = Date()
            notifySyncStateUpdate()
            notifySyncCompletion(newMessageCount: 0)
            return
        }

        // Step 2: WANT/HAVE - request messages we need
        syncLogger.info("[SYNC] WANT: \(wantIds.count) new, \(haveIds.count) have")
        let wantMsgpackArray: MessagePackValue = .array([
            .array(wantIds.map { .binary($0) }),
            .array(haveIds.map { .binary($0) }),
            .uint(UInt64(PropagationConstants.DEFAULT_PER_TRANSFER_LIMIT))
        ])

        let wantReceipt: RequestReceipt
        do {
            wantReceipt = try await link.request(
                path: PropagationConstants.SYNC_PATH,
                data: wantMsgpackArray,
                timeout: PropagationConstants.SYNC_TIMEOUT
            )
        } catch {
            syncState.state = .transferFailed
            syncState.errorDescription = "Want request failed: \(error.localizedDescription)"
            notifySyncStateUpdate()
            throw LXMFError.syncFailed("Want request failed: \(error.localizedDescription)")
        }

        // Wait for WANT response (array of message data)
        let wantResponse = try await waitForRequestResponse(wantReceipt)
        let receivedMessages = parseMessageDataArray(wantResponse)
        syncLogger.info("[SYNC] Received \(receivedMessages.count) messages (\(wantResponse.count) bytes)")

        // Process received messages through lxmfDelivery
        var newMessageCount = 0

        for (i, messageData) in receivedMessages.enumerated() {
            // Propagated messages are encrypted at the LXMF layer:
            // Format: dest_hash(16) + encrypt(source_hash + signature + packed_payload)
            // The stamp was already stripped by the server before sending.
            // We must decrypt before unpacking.
            // Reference: Python LXMRouter.py lines 2322-2328
            guard messageData.count > LXMFConstants.DESTINATION_LENGTH else {
                continue
            }

            let destHash = Data(messageData.prefix(LXMFConstants.DESTINATION_LENGTH))
            let encryptedPayload = Data(messageData.dropFirst(LXMFConstants.DESTINATION_LENGTH))

            let decryptedPayload: Data
            do {
                decryptedPayload = try identity.decrypt(encryptedPayload, identityHash: identity.hash)
            } catch {
                syncLogger.error("[SYNC] Message[\(i)] decryption failed: \(error)")
                continue
            }

            // Reconstruct plaintext LXMF message: dest_hash + source_hash + signature + payload
            let decryptedMessage = destHash + decryptedPayload

            let accepted = await lxmfDelivery(decryptedMessage)
            if accepted {
                newMessageCount += 1
            }

            syncState.receivedMessages += 1
            notifySyncStateUpdate()
        }

        // ACK ALL transient IDs from LIST (both wanted and already-had).
        // Use the server's own IDs, not recomputed ones, since the server
        // computed them from data-with-stamp but sent us data-without-stamp.
        let ackIds = transientIds

        // Step 3: ACK - tell node to delete received messages
        syncLogger.info("[SYNC] ACK \(ackIds.count) messages (\(newMessageCount) new)")
        try await sendSyncAck(link: link, ackIds: ackIds)

        // Complete
        syncState.state = .complete
        syncState.lastSync = Date()
        notifySyncStateUpdate()
        notifySyncCompletion(newMessageCount: newMessageCount)
        syncLogger.info("[SYNC] Complete: \(newMessageCount) new messages")
    }

    // MARK: - Sync Helpers

    /// Wait for a request response with timeout.
    private func waitForRequestResponse(_ receipt: RequestReceipt) async throws -> Data {
        let deadline = Date().addingTimeInterval(PropagationConstants.SYNC_TIMEOUT)

        while Date() < deadline {
            let status = await receipt.status
            switch status {
            case .responseReceived:
                if let data = await receipt.responseData {
                    return data
                }
                throw LXMFError.syncFailed("Response received but no data")
            case .failed(let reason):
                throw LXMFError.syncFailed("Request failed: \(reason)")
            case .timeout:
                throw LXMFError.syncFailed("Request timed out")
            default:
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        throw LXMFError.syncFailed("Overall sync timeout exceeded")
    }

    /// Parse the LIST response into transient IDs.
    ///
    /// The response is a msgpack array of binary transient IDs (32 bytes each).
    private func parseTransientIdList(_ data: Data) -> [Data] {
        guard let value = try? unpackLXMF(data),
              case .array(let elements) = value else {
            return []
        }

        return elements.compactMap { element in
            if case .binary(let id) = element {
                return id
            }
            return nil
        }
    }

    /// Parse the WANT response into message data blobs.
    private func parseMessageDataArray(_ data: Data) -> [Data] {
        guard let value = try? unpackLXMF(data),
              case .array(let elements) = value else {
            return []
        }

        return elements.compactMap { element in
            if case .binary(let msgData) = element {
                return msgData
            }
            return nil
        }
    }

    /// Filter transient IDs against known messages.
    ///
    /// Returns only IDs that we don't already have in the in-memory deliveredTransientIDs cache.
    private func filterTransientIds(_ ids: [Data]) -> [Data] {
        return ids.filter { id in
            deliveredTransientIDs[id] == nil
        }
    }

    /// Compute the transient ID for a packed message.
    ///
    /// Transient ID = SHA256 full hash (32 bytes) of the packed message data.
    /// This matches Python `RNS.Identity.full_hash(lxmf_data)`.
    private func computeTransientId(_ messageData: Data) -> Data {
        return Hashing.fullHash(messageData)
    }

    /// Send ACK to propagation node (Step 3).
    ///
    /// Tells the node to delete messages we've received.
    private func sendSyncAck(link: Link, ackIds: [Data]) async throws {
        let ackMsgpackValue: MessagePackValue = .array([
            .null,
            .array(ackIds.map { .binary($0) })
        ])

        _ = try await link.request(
            path: PropagationConstants.SYNC_PATH,
            data: ackMsgpackValue,
            timeout: PropagationConstants.SYNC_TIMEOUT
        )
    }

    // MARK: - Delegate Notifications

    /// Notify delegate of sync state change.
    private func notifySyncStateUpdate() {
        let state = syncState
        if let wrapper = delegateWrapper, let delegate = wrapper.delegate {
            Task { @MainActor in
                delegate.router(self, didUpdateSyncState: state)
            }
        }
    }

    /// Notify delegate of sync completion.
    private func notifySyncCompletion(newMessageCount: Int) {
        if let wrapper = delegateWrapper, let delegate = wrapper.delegate {
            Task { @MainActor in
                delegate.router(self, didCompleteSyncWithNewMessages: newMessageCount)
            }
        }
    }
}
