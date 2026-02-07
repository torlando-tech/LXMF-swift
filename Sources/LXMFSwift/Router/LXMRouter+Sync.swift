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

extension LXMRouter {

    // MARK: - Sync from Propagation Node

    /// Sync messages from the configured propagation node.
    ///
    /// Implements the 3-step sync protocol:
    /// 1. **LIST**: Request list of transient IDs available on node
    /// 2. **WANT/HAVE**: Send lists of wanted and already-have IDs, receive message data
    /// 3. **ACK**: Acknowledge received messages so node can delete them
    ///
    /// Each received message is fed through `lxmfDelivery()` for unified inbound handling.
    ///
    /// - Throws: LXMFError if propagation node not set, link fails, or sync fails
    public func syncFromPropagationNode() async throws {
        guard let propagationNode = outboundPropagationNode else {
            syncState.state = .noPath
            syncState.errorDescription = "No propagation node configured"
            throw LXMFError.propagationNodeNotSet
        }

        guard let transport = self.transport else {
            syncState.state = .linkFailed
            syncState.errorDescription = "Transport not available"
            throw LXMFError.transportNotAvailable
        }

        // Update state machine
        syncState = PropagationTransferState()
        syncState.state = .linkEstablishing
        notifySyncStateUpdate()

        let nodeHex = propagationNode.prefix(8).map { String(format: "%02x", $0) }.joined()

        // Establish link to propagation node
        let link: Link
        do {
            link = try await getOrEstablishPropagationLink(to: propagationNode, transport: transport)
            syncState.state = .linkEstablished
            notifySyncStateUpdate()
        } catch {
            syncState.state = .linkFailed
            syncState.errorDescription = error.localizedDescription
            notifySyncStateUpdate()
            throw error
        }

        // Identify ourselves
        do {
            try await link.identify(identity: identity)
        } catch {
            // Non-fatal
        }

        // Step 1: LIST - get transient IDs from node
        syncState.state = .requestSent
        notifySyncStateUpdate()

        let listRequestData = packLXMF(.array([.null, .null]))
        let listReceipt: RequestReceipt
        do {
            listReceipt = try await link.request(
                path: PropagationConstants.SYNC_PATH,
                data: listRequestData,
                timeout: PropagationConstants.SYNC_TIMEOUT
            )
        } catch {
            syncState.state = .transferFailed
            syncState.errorDescription = "List request failed: \(error.localizedDescription)"
            notifySyncStateUpdate()
            throw LXMFError.syncFailed("List request failed: \(error.localizedDescription)")
        }

        // Wait for LIST response
        let listResponse = try await waitForRequestResponse(listReceipt)
        let transientIds = parseTransientIdList(listResponse)

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
        let wantArray = LXMFMessagePackValue.array(wantIds.map { .binary($0) })
        let haveArray = LXMFMessagePackValue.array(haveIds.map { .binary($0) })
        let limit = LXMFMessagePackValue.uint(UInt64(PropagationConstants.DEFAULT_PER_TRANSFER_LIMIT))
        let wantRequestData = packLXMF(.array([wantArray, haveArray, limit]))

        let wantReceipt: RequestReceipt
        do {
            wantReceipt = try await link.request(
                path: PropagationConstants.SYNC_PATH,
                data: wantRequestData,
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

        // Process received messages through lxmfDelivery
        var newMessageCount = 0
        var ackIds: [Data] = []

        for messageData in receivedMessages {
            let accepted = await lxmfDelivery(messageData)
            if accepted {
                newMessageCount += 1
            }
            // Compute transient ID for ACK
            let transientId = computeTransientId(messageData)
            ackIds.append(transientId)

            syncState.receivedMessages += 1
            notifySyncStateUpdate()
        }

        // Also ACK messages we already had
        ackIds.append(contentsOf: haveIds)

        // Step 3: ACK - tell node to delete received messages
        try await sendSyncAck(link: link, ackIds: ackIds)

        // Complete
        syncState.state = .complete
        syncState.lastSync = Date()
        notifySyncStateUpdate()
        notifySyncCompletion(newMessageCount: newMessageCount)
    }

    // MARK: - Sync Helpers

    /// Wait for a request response with timeout.
    ///
    /// - Parameter receipt: RequestReceipt to wait on
    /// - Returns: Response data
    /// - Throws: LXMFError on timeout or failure
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
    ///
    /// - Parameter data: Response data from LIST request
    /// - Returns: Array of transient ID Data values
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
    ///
    /// - Parameter data: Response data from WANT request
    /// - Returns: Array of packed LXMF message data
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
    /// Returns only IDs that we don't already have in:
    /// - The in-memory deliveredTransientIDs cache
    ///
    /// - Parameter ids: Transient IDs from propagation node
    /// - Returns: IDs we want to receive
    private func filterTransientIds(_ ids: [Data]) -> [Data] {
        return ids.filter { id in
            deliveredTransientIDs[id] == nil
        }
    }

    /// Compute the transient ID for a packed message.
    ///
    /// Transient ID = SHA256 full hash (32 bytes) of the packed message data.
    /// This matches Python `RNS.Identity.full_hash(lxmf_data)`.
    ///
    /// - Parameter messageData: Packed LXMF message data
    /// - Returns: 32-byte transient ID
    private func computeTransientId(_ messageData: Data) -> Data {
        return Hashing.fullHash(messageData)
    }

    /// Send ACK to propagation node (Step 3).
    ///
    /// Tells the node to delete messages we've received.
    ///
    /// - Parameters:
    ///   - link: Active link to propagation node
    ///   - ackIds: Transient IDs to acknowledge
    private func sendSyncAck(link: Link, ackIds: [Data]) async throws {
        let ackArray = LXMFMessagePackValue.array(ackIds.map { .binary($0) })
        let ackData = packLXMF(.array([.null, ackArray]))

        _ = try await link.request(
            path: PropagationConstants.SYNC_PATH,
            data: ackData,
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
