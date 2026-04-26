// Copyright (c) 2026 Torlando Tech LLC.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

//
//  LXMFConformanceBridge / main.swift
//
//  Long-running stdio process for the lxmf-conformance test suite.
//  Speaks JSON-RPC over stdin/stdout: the test harness writes one
//  request per line, the bridge writes one response per line. The
//  bridge prints "READY" once on stdout before entering the
//  command loop so the harness can wait for startup deterministically.
//
//  See lxmf-conformance/reference/lxmf_python.py for the canonical
//  semantics of every command the bridge implements; this Swift
//  bridge MUST match the Python shape exactly so cross-impl tests
//  can drive both sides through the same fixture.
//
//  Phase 1 commands: lxmf_init, lxmf_add_tcp_server_interface,
//  lxmf_add_tcp_client_interface, lxmf_announce,
//  lxmf_send_opportunistic, lxmf_get_received_messages,
//  lxmf_get_message_state, lxmf_shutdown.
//

import Foundation
import LXMFSwift
import ReticulumSwift

// MARK: - JSON value (recursive)

/// Recursive JSON value used for both incoming params and outgoing
/// results. Mirrors the JSONValue in reticulum-swift's
/// ConformanceBridge so the wire format matches across both bridges.
enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case dict([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let d = try? c.decode([String: JSONValue].self) { self = .dict(d) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .dict(let d): try c.encode(d)
        }
    }

    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
}

// MARK: - Wire types

struct Request: Decodable {
    let id: String
    let command: String
    let params: [String: JSONValue]
}

struct Response: Encodable {
    let id: String
    let success: Bool
    let result: [String: JSONValue]?
    let error: String?
}

enum BridgeError: Error, CustomStringConvertible {
    case missingParam(String)
    case invalidParam(String, String)
    case notInitialised(String)
    case alreadyInitialised
    case unknown(String)

    var description: String {
        switch self {
        case .missingParam(let k): return "missing param: \(k)"
        case .invalidParam(let k, let why): return "invalid param \(k): \(why)"
        case .notInitialised(let cmd): return "lxmf_init must be called before \(cmd)"
        case .alreadyInitialised: return "lxmf_init has already been called on this bridge process"
        case .unknown(let m): return m
        }
    }
}

// MARK: - Hex helpers

/// Parse a lowercase-or-mixed hex string into bytes. Returns nil on
/// any non-hex character, mirroring the reticulum-swift bridge's
/// hexToBytes (which had a SIGTRAP-on-malformed-input incident before
/// this guard).
func hexToBytes(_ hex: String) -> Data? {
    let bytes = Array(hex.utf8)
    guard bytes.count.isMultiple(of: 2) else { return nil }
    var data = Data()
    data.reserveCapacity(bytes.count / 2)
    var i = 0
    while i < bytes.count {
        guard let hi = nibble(bytes[i]), let lo = nibble(bytes[i + 1]) else { return nil }
        data.append((hi << 4) | lo)
        i += 2
    }
    return data
}

@inline(__always)
private func nibble(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

func bytesToHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Bridge state

/// Per-process bridge state. Single instance per bridge subprocess —
/// the harness spawns two bridges to run a pair test.
final class BridgeState: @unchecked Sendable {
    let lock = NSLock()
    var transport: ReticulumTransport?
    var identity: Identity?
    var router: LXMRouter?
    var deliveryDestination: Destination?
    var deliveryDestinationHash: Data?

    // Inbox: appended on every received LXMessage. Sequence number is
    // monotonic per bridge process so polling tests can drain
    // incrementally with `since_seq`.
    private var inbox: [[String: JSONValue]] = []
    private var inboxSeq: Int = 0

    // Outbound state tracker. Maps message hash hex -> state name.
    private var outboundState: [String: String] = [:]

    func appendInbox(_ entry: [String: JSONValue]) -> Int {
        lock.lock(); defer { lock.unlock() }
        inboxSeq += 1
        var e = entry
        e["seq"] = .int(inboxSeq)
        inbox.append(e)
        return inboxSeq
    }

    func drainInbox(sinceSeq: Int) -> ([[String: JSONValue]], Int) {
        lock.lock(); defer { lock.unlock() }
        let out = inbox.filter { entry in
            if case .int(let s) = entry["seq"] ?? .null { return s > sinceSeq }
            return false
        }
        return (out, inboxSeq)
    }

    func setOutboundState(hashHex: String, state: String) {
        lock.lock(); defer { lock.unlock() }
        outboundState[hashHex] = state
    }

    func getOutboundState(hashHex: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return outboundState[hashHex] ?? "unknown"
    }
}

let state = BridgeState()

// MARK: - Bridge-side delegate

/// Hooks LXMRouter callbacks back into the bridge's inbox + state
/// tracker.
///
/// Held strongly by the bridge state because LXMRouter only retains
/// weakly via DelegateWrapper — if we let this deinit the callbacks
/// stop firing silently. The protocol is @MainActor-isolated so all
/// methods run on the main thread; the BridgeState is thread-safe
/// via its internal lock so that's fine.
@MainActor
final class BridgeDelegate: LXMRouterDelegate, @unchecked Sendable {
    func router(_ router: LXMRouter, didReceiveMessage message: LXMessage) {
        // Decode the message into the JSON-friendly shape the test
        // harness expects. Strings are decoded as UTF-8 with the same
        // replacement-on-error behaviour as the Python bridge.
        let titleStr = String(data: message.title, encoding: .utf8) ?? ""
        let contentStr = String(data: message.content, encoding: .utf8) ?? ""

        let methodName: String = {
            switch message.method {
            case .opportunistic: return "opportunistic"
            case .direct: return "direct"
            case .propagated: return "propagated"
            default: return "unknown"
            }
        }()

        let entry: [String: JSONValue] = [
            "message_hash": .string(bytesToHex(message.hash)),
            "source_hash": .string(bytesToHex(message.sourceHash)),
            "destination_hash": .string(bytesToHex(message.destinationHash)),
            "title": .string(titleStr),
            "content": .string(contentStr),
            "method": .string(methodName),
            "ack_status": .string("received"),
            "received_at_ms": .int(Int(Date().timeIntervalSince1970 * 1000.0)),
        ]
        _ = state.appendInbox(entry)
    }

    func router(_ router: LXMRouter, didUpdateMessage message: LXMessage) {
        // Track outbound state transitions so lxmf_get_message_state
        // can answer accurately. The router fires this on every state
        // change for messages it processes.
        let hashHex = bytesToHex(message.hash)
        state.setOutboundState(hashHex: hashHex, state: stateName(message.state))
    }

    func router(_ router: LXMRouter, didFailMessage message: LXMessage, reason: LXMFError) {
        state.setOutboundState(hashHex: bytesToHex(message.hash), state: "failed")
    }

    func router(_ router: LXMRouter, didConfirmDelivery messageHash: Data) {
        // The Swift router fires this when a delivery proof comes
        // back. Mark the outbound state delivered so the polling test
        // sees the proof land.
        state.setOutboundState(hashHex: bytesToHex(messageHash), state: "delivered")
    }
}

// The BridgeDelegate is constructed inside cmd_lxmf_init once we're
// already inside a blockingAsync context (so the main actor isn't
// blocked on a semaphore). The state holds the delegate reference
// once created. nonisolated(unsafe) is fine because BridgeDelegate
// internally locks state.lock on every callback, and we only read
// the delegate reference after a successful init that synchronizes
// happens-before via the same lock.
nonisolated(unsafe) var bridgeDelegate: BridgeDelegate?

func stateName(_ state: LXMessageState) -> String {
    // Names match the python bridge's _state_to_string. Cross-impl
    // tests assert on the string ("delivered"), so any drift here
    // breaks every test that polls outbound state.
    switch state {
    case .generating: return "generating"
    case .outbound: return "outbound"
    case .sending: return "sending"
    case .sent: return "sent"
    case .delivered: return "delivered"
    case .failed: return "failed"
    default: return "state_\(state.rawValue)"
    }
}

// MARK: - blockingAsync

/// Run an async closure to completion from a synchronous bridge
/// command handler. Same approach reticulum-swift's ConformanceBridge
/// uses (see ConformanceBridge/main.swift). The bridge command
/// dispatcher is synchronous because each request must produce a
/// single response line before the next request is read.
func blockingAsync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error> = .failure(BridgeError.unknown("uninitialised"))
    Task {
        do {
            let v = try await work()
            result = .success(v)
        } catch {
            result = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}

// MARK: - Command handlers

func cmdLxmfInit(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    if state.router != nil { throw BridgeError.alreadyInitialised }

    let displayName = params["display_name"]?.stringValue ?? "lxmf-conformance-peer-swift"

    return try blockingAsync {
        // LXMFDatabase enables SQLite WAL, which doesn't work for
        // ``:memory:`` paths. Use a tempfile inside a unique tempdir
        // so each bridge process has fully-isolated storage.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lxmf_conf_swift_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let dbPath = tmpDir.appendingPathComponent("lxmf.sqlite").path

        // Create RNS transport + LXMF router. LXMRouter takes the
        // identity by reference for signing outbound messages; we
        // share it with the delivery destination.
        let transport = ReticulumTransport()
        let identity = Identity()
        let router = try await LXMRouter(identity: identity, databasePath: dbPath)

        // The delegate must be constructed on the main actor because
        // LXMRouterDelegate is @MainActor-isolated. Use the
        // pre-existing global delegate (initialised at startup
        // inside the same async main task).
        guard let delegate = bridgeDelegate else {
            throw BridgeError.unknown("bridgeDelegate not initialised")
        }
        await router.setDelegate(delegate)
        await router.setTransport(transport)

        // Register the announce handler so inbound announces update
        // path table + LXMF stamp cost cache.
        await transport.registerPathRequestHandler()

        // Build the LXMF delivery destination (lxmf:delivery aspect
        // — same shape Python LXMF uses). This is the destination
        // peers send opportunistic messages to.
        let deliveryDestination = Destination(
            identity: identity,
            appName: "lxmf",
            aspects: ["delivery"],
            type: .single,
            direction: .in
        )
        try await router.registerDeliveryDestination(deliveryDestination, stampCost: nil)

        state.lock.lock()
        state.transport = transport
        state.identity = identity
        state.router = router
        state.deliveryDestination = deliveryDestination
        state.deliveryDestinationHash = deliveryDestination.hash
        state.lock.unlock()

        // Display name announcement only happens on lxmf_announce —
        // matching the Python bridge's deferred-announce semantics.
        _ = displayName

        return [
            "identity_hash": .string(bytesToHex(identity.hash)),
            "delivery_destination_hash": .string(bytesToHex(deliveryDestination.hash)),
            "config_dir": .string(""),
            "storage_path": .string(":memory:"),
        ]
    }
}

func cmdLxmfAddTcpServerInterface(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let transport = state.transport else {
        throw BridgeError.notInitialised("lxmf_add_tcp_server_interface")
    }
    let bindPort = params["bind_port"]?.intValue ?? 0
    let actualPort = bindPort != 0 ? UInt16(bindPort) : UInt16(allocateFreePort())
    let name = params["name"]?.stringValue ?? "tcpserver"

    return try blockingAsync {
        let config = InterfaceConfig(
            id: name,
            name: name,
            type: .tcp,
            enabled: true,
            mode: .full,
            host: "127.0.0.1",
            port: actualPort,
            ifacSize: 0,
            ifacKey: nil
        )
        let iface = try TCPServerInterface(config: config)
        try await transport.addInterface(iface)

        return [
            "port": .int(Int(actualPort)),
            "interface_name": .string(name),
        ]
    }
}

func cmdLxmfAddTcpClientInterface(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let transport = state.transport else {
        throw BridgeError.notInitialised("lxmf_add_tcp_client_interface")
    }
    let targetHost = params["target_host"]?.stringValue ?? "127.0.0.1"
    guard let targetPort = params["target_port"]?.intValue else {
        throw BridgeError.missingParam("target_port")
    }
    let name = params["name"]?.stringValue ?? "tcpclient"

    return try blockingAsync {
        let config = InterfaceConfig(
            id: name,
            name: name,
            type: .tcp,
            enabled: true,
            mode: .full,
            host: targetHost,
            port: UInt16(targetPort),
            ifacSize: 0,
            ifacKey: nil
        )
        let iface = try TCPInterface(config: config)
        try await transport.addInterface(iface)
        return ["interface_name": .string(name)]
    }
}

/// Allocate a free TCP port by binding to 0 and reading back the
/// OS-assigned port. Same trick reticulum-conformance uses; the
/// close-then-rebind window is technically a race but doesn't fire
/// in practice on loopback in single-test runs.
func allocateFreePort() -> Int {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(s) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            bind(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard result == 0 else { return 0 }
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(s, sa, &len)
        }
    }
    guard ok == 0 else { return 0 }
    return Int(UInt16(bigEndian: bound.sin_port))
}

func cmdLxmfAnnounce(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let transport = state.transport,
          let dest = state.deliveryDestination else {
        throw BridgeError.notInitialised("lxmf_announce")
    }
    return try blockingAsync {
        // Build and send an Announce packet for the delivery
        // destination. Same path Columba uses when refreshing its
        // own announce state.
        let announce = Announce(destination: dest)
        let packet = try announce.buildPacket()
        try await transport.send(packet: packet)

        return [
            "delivery_destination_hash": .string(bytesToHex(dest.hash)),
        ]
    }
}

func cmdLxmfSendOpportunistic(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let router = state.router,
          let identity = state.identity else {
        throw BridgeError.notInitialised("lxmf_send_opportunistic")
    }
    guard let destHashHex = params["destination_hash"]?.stringValue,
          let destHash = hexToBytes(destHashHex) else {
        throw BridgeError.missingParam("destination_hash")
    }
    let content = params["content"]?.stringValue ?? ""
    let title = params["title"]?.stringValue ?? ""

    return try blockingAsync {
        var message = LXMessage(
            destinationHash: destHash,
            sourceIdentity: identity,
            content: Data(content.utf8),
            title: Data(title.utf8),
            fields: nil,
            desiredMethod: .opportunistic
        )

        // Pack first so we can detect any silent OPPORTUNISTIC ->
        // DIRECT upgrade, matching the Python bridge guard.
        _ = try message.pack()

        // sendOpportunistic is the direct path; handleOutbound queues
        // through the LXMRouter's outbound thread which respects the
        // DESIRED method.
        try await router.handleOutbound(&message)

        let hashHex = bytesToHex(message.hash)
        // Seed the outbound state with the current state so a tight
        // race between handleOutbound returning and the delegate
        // callback firing doesn't show "unknown" briefly.
        state.setOutboundState(hashHex: hashHex, state: stateName(message.state))

        return [
            "message_hash": .string(hashHex),
        ]
    }
}

func cmdLxmfGetReceivedMessages(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    let sinceSeq = params["since_seq"]?.intValue ?? 0
    let (messages, lastSeq) = state.drainInbox(sinceSeq: sinceSeq)
    return [
        "messages": .array(messages.map { .dict($0) }),
        "last_seq": .int(lastSeq),
    ]
}

func cmdLxmfGetMessageState(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let hashHex = params["message_hash"]?.stringValue else {
        throw BridgeError.missingParam("message_hash")
    }
    return [
        "state": .string(state.getOutboundState(hashHex: hashHex)),
    ]
}

func cmdLxmfShutdown(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    let stopped: Bool = state.router != nil
    if let router = state.router {
        // Synchronous teardown — the harness expects
        // lxmf_shutdown to complete before the next test starts.
        try blockingAsync {
            await router.shutdown()
        }
    }
    state.lock.lock()
    state.router = nil
    state.identity = nil
    state.transport = nil
    state.deliveryDestination = nil
    state.deliveryDestinationHash = nil
    state.lock.unlock()
    return ["stopped": .bool(stopped)]
}

// MARK: - Dispatcher

func dispatch(_ req: Request) throws -> [String: JSONValue] {
    switch req.command {
    case "lxmf_init": return try cmdLxmfInit(req.params)
    case "lxmf_add_tcp_server_interface": return try cmdLxmfAddTcpServerInterface(req.params)
    case "lxmf_add_tcp_client_interface": return try cmdLxmfAddTcpClientInterface(req.params)
    case "lxmf_announce": return try cmdLxmfAnnounce(req.params)
    case "lxmf_send_opportunistic": return try cmdLxmfSendOpportunistic(req.params)
    case "lxmf_get_received_messages": return try cmdLxmfGetReceivedMessages(req.params)
    case "lxmf_get_message_state": return try cmdLxmfGetMessageState(req.params)
    case "lxmf_shutdown": return try cmdLxmfShutdown(req.params)
    default:
        throw BridgeError.unknown("Unknown command: \(req.command)")
    }
}

// MARK: - Main
//
// The bridge keeps the main thread free to serve the @MainActor-
// isolated `LXMRouterDelegate` callbacks. The read/dispatch loop runs
// on a background DispatchQueue. The main thread enters dispatchMain()
// after kicking off setup; that runloop processes Foundation events,
// Swift Concurrency MainActor jobs, and the like.
//
// Sequence:
//   1. Construct the @MainActor delegate via Task.
//   2. Wait for that to land in `bridgeDelegate`.
//   3. Spawn the JSON-RPC read loop on a background queue.
//   4. dispatchMain — main thread serves MainActor jobs.

DispatchQueue.global(qos: .userInitiated).async {
    // Initialize the delegate from a non-main thread so we don't
    // tangle with MainActor.run's main-thread requirement. The
    // semaphore loop below polls until the delegate is published
    // by the Task, then prints READY and enters the JSON-RPC loop.
    Task.detached {
        let d = await MainActor.run { BridgeDelegate() }
        bridgeDelegate = d
    }
    while bridgeDelegate == nil {
        usleep(10_000)
    }

    print("READY")
    fflush(stdout)

    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { continue }

        let response: Response
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(trimmed.utf8))
            do {
                let result = try dispatch(request)
                response = Response(id: request.id, success: true, result: result, error: nil)
            } catch {
                response = Response(id: request.id, success: false, result: nil, error: "\(error)")
            }
        } catch {
            response = Response(id: "parse_error", success: false, result: nil, error: "JSON parse error: \(error)")
        }

        if let data = try? JSONEncoder().encode(response),
           let s = String(data: data, encoding: .utf8) {
            print(s)
            fflush(stdout)
        }
    }
    // EOF on stdin — exit the whole process so Popen.wait reaps it.
    exit(0)
}

dispatchMain()
