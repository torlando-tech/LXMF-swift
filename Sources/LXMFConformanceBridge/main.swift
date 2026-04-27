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
    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d):
            // `Int(_:)` traps on NaN, ±Infinity, and any value outside
            // [Int.min, Int.max]. JSON floats like 1e300 are valid
            // input, so guard here to return nil and let the caller's
            // missing/invalid-param error bubble up.
            guard d.isFinite, d >= Double(Int.min), d <= Double(Int.max) else { return nil }
            return Int(d)
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

// MARK: - LXMF field encoding

/// Convert an LXMF field value (as it lives inside `LXMessage.fields`)
/// to a JSON-safe shape for the bridge inbox. `Data` becomes a hex
/// string at any depth so `JSONEncoder` can render it; lists and dicts
/// are walked recursively. Mirrors the python bridge's
/// `_encode_field_value_for_inbox` so both impls serialize attachments
/// identically for tight cross-impl assertions.
func encodeFieldValueForInbox(_ value: Any) -> JSONValue {
    if let data = value as? Data {
        return .string(bytesToHex(data))
    }
    if let str = value as? String {
        return .string(str)
    }
    if let b = value as? Bool {
        return .bool(b)
    }
    if let i = value as? Int {
        return .int(i)
    }
    if let i = value as? Int64 {
        return .int(Int(i))
    }
    if let i = value as? UInt64 {
        return .int(Int(i))
    }
    if let d = value as? Double {
        return .double(d)
    }
    if let arr = value as? [Any] {
        return .array(arr.map(encodeFieldValueForInbox))
    }
    if let dict = value as? [String: Any] {
        var out: [String: JSONValue] = [:]
        for (k, v) in dict { out[k] = encodeFieldValueForInbox(v) }
        return .dict(out)
    }
    return .null
}

/// Decode the wire-format `fields` parameter on a send command into the
/// `[UInt8: Any]` shape `LXMessage.init(fields:)` expects.
///
/// Wire format mirrors reticulum-conformance / python lxmf-conformance:
///   {"bytes": "<hex>"}  -> Data
///   {"str": "..."}       -> String
///   {"int": 123}          -> Int
///   {"bool": true}        -> Bool
///   JSON arrays           -> [Any] (recursive)
///   bare primitives       -> their native type (passthrough)
func decodeFieldValue(_ value: JSONValue) throws -> Any {
    switch value {
    case .dict(let d):
        if case .string(let hex) = d["bytes"] ?? .null {
            guard let data = hexToBytes(hex) else {
                throw BridgeError.invalidParam("fields", "invalid hex in {bytes: ...}: \(hex)")
            }
            return data
        }
        if case .string(let s) = d["str"] ?? .null { return s }
        if case .int(let i) = d["int"] ?? .null { return i }
        if case .double(let dv) = d["int"] ?? .null { return Int(dv) }
        if case .bool(let b) = d["bool"] ?? .null { return b }
        throw BridgeError.invalidParam(
            "fields",
            "unsupported field object shape; expected {bytes|str|int|bool}"
        )
    case .array(let arr):
        return try arr.map(decodeFieldValue)
    case .string(let s): return s
    case .int(let i): return i
    case .double(let d): return d
    case .bool(let b): return b
    case .null: return NSNull()
    }
}

func decodeFieldsParam(_ raw: JSONValue?) throws -> [UInt8: Any]? {
    guard let raw, case .dict(let d) = raw, !d.isEmpty else { return nil }
    var out: [UInt8: Any] = [:]
    for (k, v) in d {
        guard let key = UInt8(k) else {
            throw BridgeError.invalidParam("fields", "field key must be 0..255: \(k)")
        }
        out[key] = try decodeFieldValue(v)
    }
    return out
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
    /// Display name passed to `lxmf_init`; emitted in announce app-data
    /// to match the Python bridge, which forwards `display_name` into
    /// `register_delivery_identity` so it lands on every announce.
    var displayName: String?
    /// Tempdir created in `lxmf_init` for the SQLite database. Stored
    /// so `lxmf_shutdown` can clean it up; otherwise a long-running
    /// harness accumulates one stale `lxmf_conf_swift_<UUID>` per test.
    var tmpDir: URL?

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

    /// Set the outbound state only if no entry exists for this hash.
    /// Used by send commands to seed an initial state without
    /// clobbering a delegate-driven update that landed first (the
    /// outbound thread can run sendDirect/sendOpportunistic before
    /// `handleOutbound` returns to the caller, in which case the
    /// delegate-updated `.sent` would be overwritten by an unconditional
    /// seed of `.outbound`).
    func seedOutboundState(hashHex: String, state: String) {
        lock.lock(); defer { lock.unlock() }
        if outboundState[hashHex] == nil {
            outboundState[hashHex] = state
        }
    }

    func getOutboundState(hashHex: String) -> String {
        lock.lock(); defer { lock.unlock() }
        return outboundState[hashHex] ?? "unknown"
    }

    /// Wipe inbox + outbound state. Called from `cmdLxmfShutdown` so a
    /// harness that reuses a bridge process across test cases doesn't
    /// see stale messages from the previous session on the next
    /// `lxmf_get_received_messages` / `lxmf_get_message_state` call.
    func resetMessaging() {
        lock.lock(); defer { lock.unlock() }
        inbox.removeAll()
        inboxSeq = 0
        outboundState.removeAll()
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

        // LXMF fields surface as a JSON dict keyed by the field id
        // (decimal string), with leaf bytes hex-encoded — matches the
        // python bridge's `_encode_message_fields` so cross-impl tests
        // can compare attachment payloads byte-for-byte.
        var fieldsJson: [String: JSONValue] = [:]
        if let fields = message.fields {
            for (key, value) in fields {
                fieldsJson[String(key)] = encodeFieldValueForInbox(value)
            }
        }

        let entry: [String: JSONValue] = [
            "message_hash": .string(bytesToHex(message.hash)),
            "source_hash": .string(bytesToHex(message.sourceHash)),
            "destination_hash": .string(bytesToHex(message.destinationHash)),
            "title": .string(titleStr),
            "content": .string(contentStr),
            "method": .string(methodName),
            "ack_status": .string("received"),
            "received_at_ms": .int(Int(Date().timeIntervalSince1970 * 1000.0)),
            "fields": .dict(fieldsJson),
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
///
/// The result is stashed inside a reference-typed `Box` so the
/// capture stays Swift 6 strict-concurrency-clean: a `var` captured
/// and mutated from the @Sendable Task closure would error under
/// `-strict-concurrency=complete`. The semaphore still provides the
/// happens-before edge between the writer and the reader on the
/// caller's thread.
private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error> = .failure(BridgeError.unknown("uninitialised"))
}

func blockingAsync<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        do {
            box.value = .success(try await work())
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    return try box.value.get()
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
        // Store display name + tmp dir so cmdLxmfAnnounce can include
        // the name in announce app-data and cmdLxmfShutdown can clean
        // up the SQLite tempdir.
        state.displayName = displayName
        state.tmpDir = tmpDir
        state.lock.unlock()

        return [
            "identity_hash": .string(bytesToHex(identity.hash)),
            "delivery_destination_hash": .string(bytesToHex(deliveryDestination.hash)),
            "config_dir": .string(""),
            "storage_path": .string(dbPath),
        ]
    }
}

func cmdLxmfAddTcpServerInterface(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let transport = state.transport else {
        throw BridgeError.notInitialised("lxmf_add_tcp_server_interface")
    }
    let bindPort = params["bind_port"]?.intValue ?? 0
    // Range-check explicitly so an out-of-range port from the harness
    // returns a JSON error instead of trapping in `UInt16(_:)`.
    guard (0...65535).contains(bindPort) else {
        throw BridgeError.invalidParam("bind_port", "must be in 0...65535, got \(bindPort)")
    }
    let actualPort: UInt16
    if bindPort != 0 {
        actualPort = UInt16(bindPort)
    } else {
        guard let allocated = allocateFreePort() else {
            throw BridgeError.unknown("allocateFreePort failed")
        }
        actualPort = UInt16(allocated)
    }
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
        // Register every spawned peer with the Transport on connect.
        // Without this, inbound packets on the spawned child interface
        // (the python TCPClient's announce, proof, etc.) reach the
        // Transport's `receive(packet:from:)` with an interfaceId the
        // Transport doesn't know about → the packet is dropped before
        // path-table updates run, so the swift server side never learns
        // the peer's identity. Mirrors reticulum-swift's own
        // ConformanceBridge/WireTcp.swift:319-343.
        iface.onClientConnected = { [weak transport] spawned in
            guard let transport else { return }
            do {
                try blockingAsync {
                    try await transport.addInterface(spawned)
                }
            } catch {
                FileHandle.standardError.write(
                    Data("[LXMFBridge] Failed to register spawned peer \(spawned.id): \(error)\n".utf8)
                )
            }
        }
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
    // Range-check explicitly so an out-of-range port from the harness
    // returns a JSON error instead of trapping in `UInt16(_:)`.
    guard (0...65535).contains(targetPort) else {
        throw BridgeError.invalidParam("target_port", "must be in 0...65535, got \(targetPort)")
    }
    let portU16 = UInt16(targetPort)
    let name = params["name"]?.stringValue ?? "tcpclient"

    return try blockingAsync {
        let config = InterfaceConfig(
            id: name,
            name: name,
            type: .tcp,
            enabled: true,
            mode: .full,
            host: targetHost,
            port: portU16,
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
///
/// Returns nil (rather than 0) on bind/getsockname failure so the
/// caller surfaces a JSON error instead of silently passing port 0
/// downstream where it would either bind ephemerally or fail in a
/// hard-to-trace way.
func allocateFreePort() -> Int? {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    guard s >= 0 else { return nil }
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
    guard result == 0 else { return nil }
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getsockname(s, sa, &len)
        }
    }
    guard ok == 0 else { return nil }
    return Int(UInt16(bigEndian: bound.sin_port))
}

func cmdLxmfAnnounce(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let transport = state.transport,
          let dest = state.deliveryDestination else {
        throw BridgeError.notInitialised("lxmf_announce")
    }
    // Match the python bridge: `display_name` from lxmf_init is
    // emitted as the announce app-data so cross-impl tests that read
    // announces see the configured name, not the default.
    state.lock.lock()
    let appData = state.displayName.flatMap { Data($0.utf8) }
    state.lock.unlock()
    return try blockingAsync {
        let announce = Announce(destination: dest, appData: appData)
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
    guard let destHashHex = params["destination_hash"]?.stringValue else {
        throw BridgeError.missingParam("destination_hash")
    }
    guard let destHash = hexToBytes(destHashHex) else {
        throw BridgeError.invalidParam("destination_hash", "invalid hex string: \(destHashHex)")
    }
    let content = params["content"]?.stringValue ?? ""
    let title = params["title"]?.stringValue ?? ""
    let fields = try decodeFieldsParam(params["fields"])

    return try blockingAsync {
        var message = LXMessage(
            destinationHash: destHash,
            sourceIdentity: identity,
            content: Data(content.utf8),
            title: Data(title.utf8),
            fields: fields,
            desiredMethod: .opportunistic
        )

        // Pack first so we can detect any silent OPPORTUNISTIC ->
        // DIRECT upgrade, matching the Python bridge guard. The Swift
        // router's outbound path falls back to a different method
        // when packed payload exceeds ENCRYPTED_PACKET_MAX_CONTENT
        // (LXMRouter.handleOutbound applies the same formula). Surface
        // that as an explicit error so the harness sees a typed
        // failure instead of a silent method change.
        let packed = try message.pack()
        let packedPayloadSize = packed.count
            - (2 * LXMFConstants.DESTINATION_LENGTH + LXMFConstants.SIGNATURE_LENGTH)
        if packedPayloadSize > LXMFConstants.ENCRYPTED_PACKET_MAX_CONTENT {
            throw BridgeError.invalidParam(
                "content",
                "opportunistic content would silently upgrade: packedPayloadSize=\(packedPayloadSize) > ENCRYPTED_PACKET_MAX_CONTENT=\(LXMFConstants.ENCRYPTED_PACKET_MAX_CONTENT)"
            )
        }

        // sendOpportunistic is the direct path; handleOutbound queues
        // through the LXMRouter's outbound thread which respects the
        // DESIRED method.
        try await router.handleOutbound(&message)

        let hashHex = bytesToHex(message.hash)
        // Seed the outbound state ONLY if no delegate update has
        // landed yet. Without the conditional, a fast outbound thread
        // can call notifyUpdate(message: .sent) before this line runs;
        // an unconditional set then overwrites `.sent` with `.outbound`
        // and the test sees the wrong state forever.
        state.seedOutboundState(hashHex: hashHex, state: stateName(message.state))

        return [
            "message_hash": .string(hashHex),
        ]
    }
}

/// Send a DIRECT (link-based) LXMF message. Mirrors python bridge's
/// cmd_lxmf_send_direct: same param shape, same response. The router
/// establishes an outbound link to the recipient and delivers the
/// packed message over it. No size guard here — DIRECT links can
/// fragment via Resource transfer when the message exceeds
/// LINK_PACKET_MAX_CONTENT.
func cmdLxmfSendDirect(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let router = state.router,
          let identity = state.identity else {
        throw BridgeError.notInitialised("lxmf_send_direct")
    }
    guard let destHashHex = params["destination_hash"]?.stringValue else {
        throw BridgeError.missingParam("destination_hash")
    }
    guard let destHash = hexToBytes(destHashHex) else {
        throw BridgeError.invalidParam("destination_hash", "invalid hex string: \(destHashHex)")
    }
    let content = params["content"]?.stringValue ?? ""
    let title = params["title"]?.stringValue ?? ""
    let fields = try decodeFieldsParam(params["fields"])

    return try blockingAsync {
        var message = LXMessage(
            destinationHash: destHash,
            sourceIdentity: identity,
            content: Data(content.utf8),
            title: Data(title.utf8),
            fields: fields,
            desiredMethod: .direct
        )
        try await router.handleOutbound(&message)
        let hashHex = bytesToHex(message.hash)
        state.seedOutboundState(hashHex: hashHex, state: stateName(message.state))
        return ["message_hash": .string(hashHex)]
    }
}

/// Return whether the router's path table currently has a path entry
/// for `destination_hash`. Lets test fixtures poll for convergence in
/// multi-bridge topologies instead of guessing a settle time.
func cmdLxmfHasPath(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let router = state.router else {
        throw BridgeError.notInitialised("lxmf_has_path")
    }
    guard let hashHex = params["destination_hash"]?.stringValue,
          let destHash = hexToBytes(hashHex) else {
        throw BridgeError.missingParam("destination_hash")
    }
    return try blockingAsync {
        let hasPath = await router.hasPath(destHash)
        return ["has_path": .bool(hasPath)]
    }
}

/// Configure this peer's outbound propagation node. Mirrors python's
/// `cmd_lxmf_set_outbound_propagation_node`; once set, `lxmf_send_propagated`
/// will queue messages routed through that node.
func cmdLxmfSetOutboundPropagationNode(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let router = state.router else {
        throw BridgeError.notInitialised("lxmf_set_outbound_propagation_node")
    }
    guard let hashHex = params["destination_hash"]?.stringValue,
          let destHash = hexToBytes(hashHex) else {
        throw BridgeError.missingParam("destination_hash")
    }
    let stampCost = params["stamp_cost"]?.intValue
    return try blockingAsync {
        await router.setOutboundPropagationNode(destHash)
        if let stampCost {
            await router.setPropagationStampCost(stampCost)
        }
        return ["ok": .bool(true)]
    }
}

/// Submit a PROPAGATED LXMF message via the configured propagation node.
/// Same param shape as `lxmf_send_direct` — the only difference is the
/// `desiredMethod`, which routes the message through the LXMRouter
/// outbound propagation queue instead of opening a direct link to the
/// recipient.
func cmdLxmfSendPropagated(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let router = state.router,
          let identity = state.identity else {
        throw BridgeError.notInitialised("lxmf_send_propagated")
    }
    guard let destHashHex = params["destination_hash"]?.stringValue else {
        throw BridgeError.missingParam("destination_hash")
    }
    guard let destHash = hexToBytes(destHashHex) else {
        throw BridgeError.invalidParam("destination_hash", "invalid hex string: \(destHashHex)")
    }
    let content = params["content"]?.stringValue ?? ""
    let title = params["title"]?.stringValue ?? ""
    let fields = try decodeFieldsParam(params["fields"])

    return try blockingAsync {
        var message = LXMessage(
            destinationHash: destHash,
            sourceIdentity: identity,
            content: Data(content.utf8),
            title: Data(title.utf8),
            fields: fields,
            desiredMethod: .propagated
        )
        try await router.handleOutbound(&message)
        let hashHex = bytesToHex(message.hash)
        state.seedOutboundState(hashHex: hashHex, state: stateName(message.state))
        return ["message_hash": .string(hashHex)]
    }
}

/// Pull messages from the configured propagation node.
///
/// Wraps `LXMRouter.syncFromPropagationNode` and waits up to
/// `timeout_sec` for the transfer state to settle. Returns the final
/// state name so tests can assert success / failure.
func cmdLxmfSyncInbound(_ params: [String: JSONValue]) throws -> [String: JSONValue] {
    guard let router = state.router else {
        throw BridgeError.notInitialised("lxmf_sync_inbound")
    }
    let timeoutSec = params["timeout_sec"]?.doubleValue ?? 30.0
    return try blockingAsync {
        do {
            try await router.syncFromPropagationNode()
        } catch {
            return [
                "final_state": .string("failed"),
                "error": .string("\(error)"),
            ]
        }
        // Poll the actor's syncState until it reaches a terminal value
        // (`done` / `failed` / `noPath` / `linkFailed`) or the timeout
        // elapses. The active states (`linkEstablishing`, `transferring`,
        // …) drive an internal LXMF transfer; we wait on them so the
        // returned `final_state` reflects the actual outcome.
        let deadline = Date().addingTimeInterval(timeoutSec)
        var finalState = await router.syncState.state
        while Date() < deadline {
            finalState = await router.syncState.state
            if isSyncTerminalState(finalState) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        return ["final_state": .string("\(finalState)")]
    }
}

private func isSyncTerminalState(_ state: PropagationState) -> Bool {
    switch state {
    case .idle, .complete, .noPath, .linkFailed, .transferFailed: return true
    default: return false
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
    let router = state.router
    let transport = state.transport
    if router != nil || transport != nil {
        // Synchronous teardown — the harness expects
        // lxmf_shutdown to complete before the next test starts. The
        // transport teardown matters when the harness reuses a single
        // bridge process across multiple test cases: without it,
        // bound TCP server sockets would remain open and the next
        // `lxmf_add_tcp_server_interface` on the same port would
        // fail to bind.
        try blockingAsync {
            await router?.shutdown()
            if let transport {
                await transport.stopRetransmissionLoop()
                let snapshots = await transport.getInterfaceSnapshots()
                for snapshot in snapshots {
                    await transport.removeInterface(id: snapshot.id)
                }
            }
        }
    }
    state.lock.lock()
    state.router = nil
    state.identity = nil
    state.transport = nil
    state.deliveryDestination = nil
    state.deliveryDestinationHash = nil
    state.displayName = nil
    let tmpDir = state.tmpDir
    state.tmpDir = nil
    state.lock.unlock()
    // Wipe inbox + outbound state so a subsequent lxmf_init in the
    // same bridge process doesn't surface stale messages from the
    // previous session.
    state.resetMessaging()
    // Remove the SQLite tempdir so a long-running harness doesn't
    // accumulate one stale `lxmf_conf_swift_<UUID>` per test pair.
    if let tmpDir {
        try? FileManager.default.removeItem(at: tmpDir)
    }
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
    case "lxmf_send_direct": return try cmdLxmfSendDirect(req.params)
    case "lxmf_has_path": return try cmdLxmfHasPath(req.params)
    case "lxmf_set_outbound_propagation_node": return try cmdLxmfSetOutboundPropagationNode(req.params)
    case "lxmf_send_propagated": return try cmdLxmfSendPropagated(req.params)
    case "lxmf_sync_inbound": return try cmdLxmfSyncInbound(req.params)
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
    // tangle with MainActor.run's main-thread requirement. Use a
    // DispatchSemaphore for hand-off: the semaphore wait/signal pair
    // gives a real happens-before edge from the writer to the reader,
    // unlike a plain spin-wait on a `nonisolated(unsafe) var` which
    // relies on incidental syscall-as-barrier behaviour.
    let delegateReady = DispatchSemaphore(value: 0)
    Task.detached {
        let d = await MainActor.run { BridgeDelegate() }
        bridgeDelegate = d
        delegateReady.signal()
    }
    delegateReady.wait()

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
        } else {
            // Encoding the structured response failed. The harness is
            // line-blocked waiting for *something*, so emit a hand-
            // rolled minimal error frame rather than silently dropping
            // the line and hanging the test.
            let id = response.id.replacingOccurrences(of: "\"", with: "\\\"")
            print("{\"id\":\"\(id)\",\"success\":false,\"error\":\"response encode failed\"}")
            fflush(stdout)
        }
    }
    // EOF on stdin — exit the whole process so Popen.wait reaps it.
    exit(0)
}

dispatchMain()
