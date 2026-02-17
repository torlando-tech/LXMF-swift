//
//  Telemetry.swift
//  LXMFSwift
//
//  Sideband-compatible telemetry encoding/decoding for LXMF FIELD_TELEMETRY.
//  Wire format matches Python Sideband Telemeter sensor format exactly.
//
//  Telemetry dict is "double-packed": inner dict msgpacked to bytes,
//  stored as Data field value in the LXMF fields map.
//
//  Reference: Sideband/core/telemeter.py, Columba-Android TelemetryCodec.kt
//

import Foundation

// MARK: - LXMF Telemetry Field Constants

extension LXMessage {
    /// Telemetry dict (double-packed: inner dict msgpacked to bytes).
    public static let FIELD_TELEMETRY: UInt8 = 0x02

    /// Bulk telemetry from collectors.
    public static let FIELD_TELEMETRY_STREAM: UInt8 = 0x03

    /// Telemetry request/ping commands.
    public static let FIELD_COMMANDS: UInt8 = 0x09
}

// MARK: - Sensor IDs

/// Sideband telemetry sensor ID constants.
public enum TelemetrySensorID: UInt8 {
    case time = 0x01
    case location = 0x02
    case pressure = 0x03
    case battery = 0x04
    case temperature = 0x05
    case humidity = 0x06
    case magneticField = 0x07
    case ambientLight = 0x08
    case gravity = 0x09
    case angularVelocity = 0x0A
    case acceleration = 0x0B
    case proximity = 0x0C
}

// MARK: - LocationTelemetry

/// Sideband-compatible location telemetry data.
///
/// Encodes/decodes the 7-element SID_LOCATION sensor array:
/// - Indices 0-5: big-endian struct-packed binary Data blobs (matches Python `struct.pack("!i", ...)`)
/// - Index 6: plain msgpack integer (Unix timestamp)
public struct LocationTelemetry: Equatable, Sendable {

    /// Latitude in degrees.
    public var latitude: Double

    /// Longitude in degrees.
    public var longitude: Double

    /// Altitude in meters.
    public var altitude: Double

    /// Speed in m/s.
    public var speed: Double

    /// Bearing in degrees (0-360).
    public var bearing: Double

    /// Horizontal accuracy in meters.
    public var accuracy: Double

    /// Last update timestamp (Unix seconds).
    public var lastUpdate: Int

    public init(latitude: Double, longitude: Double, altitude: Double,
                speed: Double, bearing: Double, accuracy: Double, lastUpdate: Int) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speed = speed
        self.bearing = bearing
        self.accuracy = accuracy
        self.lastUpdate = lastUpdate
    }

    /// True when all values are zero (cease signal).
    public var isCeased: Bool {
        latitude == 0 && longitude == 0 && altitude == 0 &&
        speed == 0 && bearing == 0 && accuracy == 0 && lastUpdate == 0
    }

    /// Create a cease signal (all zeros).
    public static func ceaseSignal() -> LocationTelemetry {
        LocationTelemetry(latitude: 0, longitude: 0, altitude: 0,
                          speed: 0, bearing: 0, accuracy: 0, lastUpdate: 0)
    }

    // MARK: - Encoding

    /// Encode to the 7-element Sideband sensor array format.
    ///
    /// Elements 0-5 are big-endian struct-packed Data blobs.
    /// Element 6 is a plain integer.
    ///
    /// - Returns: Array of msgpack-compatible values
    public func toSensorArray() -> [LXMFMessagePackValue] {
        return [
            .binary(packInt32(Int32(latitude * 1_000_000))),    // microdegrees
            .binary(packInt32(Int32(longitude * 1_000_000))),   // microdegrees
            .binary(packInt32(Int32(altitude * 100))),          // centimeters
            .binary(packUInt32(UInt32(max(0, speed * 100)))),   // cm/s
            .binary(packInt32(Int32(bearing * 100))),           // centi-degrees
            .binary(packUInt16(UInt16(min(65535, max(0, accuracy * 100))))), // centimeters (max 655.35m)
            .int(Int64(lastUpdate))
        ]
    }

    // MARK: - Decoding

    /// Decode from a 7-element Sideband sensor array.
    ///
    /// - Parameter array: Msgpack array values from SID_LOCATION
    /// - Returns: Decoded LocationTelemetry, or nil if format is invalid
    public static func fromSensorArray(_ array: [LXMFMessagePackValue]) -> LocationTelemetry? {
        guard array.count >= 7 else { return nil }

        // Extract binary blobs for indices 0-5
        guard case .binary(let latData) = array[0], latData.count == 4,
              case .binary(let lonData) = array[1], lonData.count == 4,
              case .binary(let altData) = array[2], altData.count == 4,
              case .binary(let spdData) = array[3], spdData.count == 4,
              case .binary(let brgData) = array[4], brgData.count == 4,
              case .binary(let accData) = array[5], accData.count == 2 else {
            return nil
        }

        // Extract timestamp (index 6) as integer
        let timestamp: Int
        switch array[6] {
        case .int(let i): timestamp = Int(i)
        case .uint(let u): timestamp = Int(u)
        default: return nil
        }

        return LocationTelemetry(
            latitude: Double(unpackInt32(latData)) / 1_000_000.0,
            longitude: Double(unpackInt32(lonData)) / 1_000_000.0,
            altitude: Double(unpackInt32(altData)) / 100.0,
            speed: Double(unpackUInt32(spdData)) / 100.0,
            bearing: Double(unpackInt32(brgData)) / 100.0,
            accuracy: Double(unpackUInt16(accData)) / 100.0,
            lastUpdate: timestamp
        )
    }

    // MARK: - Binary Helpers

    /// Pack Int32 as 4-byte big-endian Data (matches Python `struct.pack("!i", val)`).
    private func packInt32(_ val: Int32) -> Data {
        var be = val.bigEndian
        return Data(bytes: &be, count: 4)
    }

    /// Pack UInt32 as 4-byte big-endian Data (matches Python `struct.pack("!I", val)`).
    private func packUInt32(_ val: UInt32) -> Data {
        var be = val.bigEndian
        return Data(bytes: &be, count: 4)
    }

    /// Pack UInt16 as 2-byte big-endian Data (matches Python `struct.pack("!H", val)`).
    private func packUInt16(_ val: UInt16) -> Data {
        var be = val.bigEndian
        return Data(bytes: &be, count: 2)
    }

    /// Unpack 4-byte big-endian Data to Int32.
    private static func unpackInt32(_ data: Data) -> Int32 {
        data.withUnsafeBytes { $0.load(as: Int32.self).bigEndian }
    }

    /// Unpack 4-byte big-endian Data to UInt32.
    private static func unpackUInt32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    }

    /// Unpack 2-byte big-endian Data to UInt16.
    private static func unpackUInt16(_ data: Data) -> UInt16 {
        data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
    }
}

// MARK: - TelemetryPacket

/// Represents a complete telemetry packet with timestamp and sensor data.
///
/// The FIELD_TELEMETRY value is double-packed: the inner dict is msgpacked
/// to bytes, then stored as a Data field value in the LXMF fields map.
public struct TelemetryPacket: Equatable, Sendable {

    /// Packet timestamp (Unix seconds).
    public var timestamp: Int

    /// Location sensor data (nil if not present).
    public var location: LocationTelemetry?

    public init(timestamp: Int, location: LocationTelemetry?) {
        self.timestamp = timestamp
        self.location = location
    }

    /// Encode the telemetry packet to msgpack bytes for FIELD_TELEMETRY.
    ///
    /// Produces a msgpack dict with integer sensor ID keys in ascending order
    /// (matching Python dict insertion order): `{1: timestamp, 2: [7-element array]}`
    ///
    /// - Returns: Msgpack-encoded bytes
    public func encode() -> Data {
        // Build ordered key-value pairs (ascending sensor ID) to match Python's
        // dict insertion order and produce deterministic byte output.
        var pairs: [(LXMFMessagePackValue, LXMFMessagePackValue)] = []
        pairs.append((.uint(UInt64(TelemetrySensorID.time.rawValue)), .int(Int64(timestamp))))
        if let location = location {
            pairs.append((.uint(UInt64(TelemetrySensorID.location.rawValue)), .array(location.toSensorArray())))
        }

        // Encode map manually with guaranteed key order
        var data = Data()
        // fixmap header: 0x80 | count
        data.append(UInt8(0x80 | pairs.count))
        for (key, value) in pairs {
            let keyBytes = packLXMF(key)
            let valBytes = packLXMF(value)
            data.append(keyBytes)
            data.append(valBytes)
        }
        return data
    }

    /// Decode a telemetry packet from msgpack bytes (FIELD_TELEMETRY value).
    ///
    /// - Parameter data: Msgpack-encoded bytes from the field value
    /// - Returns: Decoded TelemetryPacket, or nil if format is invalid
    public static func decode(from data: Data) -> TelemetryPacket? {
        guard let value = try? unpackLXMF(data),
              case .map(let dict) = value else {
            return nil
        }

        // Extract timestamp
        let timeKey = LXMFMessagePackValue.uint(UInt64(TelemetrySensorID.time.rawValue))
        let timestamp: Int
        if let timeVal = dict[timeKey] {
            switch timeVal {
            case .int(let i): timestamp = Int(i)
            case .uint(let u): timestamp = Int(u)
            default: timestamp = Int(Date().timeIntervalSince1970)
            }
        } else {
            timestamp = Int(Date().timeIntervalSince1970)
        }

        // Extract location
        let locKey = LXMFMessagePackValue.uint(UInt64(TelemetrySensorID.location.rawValue))
        var location: LocationTelemetry? = nil
        if let locVal = dict[locKey], case .array(let arr) = locVal {
            location = LocationTelemetry.fromSensorArray(arr)
        }

        return TelemetryPacket(timestamp: timestamp, location: location)
    }
}
