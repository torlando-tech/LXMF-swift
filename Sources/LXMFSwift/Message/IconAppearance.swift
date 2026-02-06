//
//  IconAppearance.swift
//  LXMFSwift
//
//  LXMF Field 4 icon appearance data.
//  Interoperable with Sideband, MeshChat, and Columba Android.
//
//  Wire format: msgpack array [icon_name: string, fg_color: bytes(3 RGB), bg_color: bytes(3 RGB)]
//

import Foundation

/// LXMF Field 4 icon appearance data.
///
/// Represents an MDI icon with foreground and background colors,
/// transmitted in LXMF message fields[0x04] for cross-client avatar display.
public struct IconAppearance: Codable, Sendable, Equatable {
    /// MDI icon name (e.g., "account", "star", "radio").
    public let iconName: String

    /// Foreground color as 6-char hex RGB (e.g., "FFFFFF").
    public let foregroundColor: String

    /// Background color as 6-char hex RGB (e.g., "1E88E5").
    public let backgroundColor: String

    /// LXMF field key for icon appearance.
    public static let fieldKey: UInt8 = 0x04

    public init(iconName: String, foregroundColor: String, backgroundColor: String) {
        self.iconName = iconName
        self.foregroundColor = foregroundColor
        self.backgroundColor = backgroundColor
    }

    /// Pack to LXMF Field 4 wire format: [name, fg_bytes(3), bg_bytes(3)].
    public func toLXMFFieldValue() -> [Any] {
        let fgBytes = Self.hexToRGBData(foregroundColor)
        let bgBytes = Self.hexToRGBData(backgroundColor)
        return [iconName, fgBytes, bgBytes]
    }

    /// Parse from LXMF Field 4 wire format.
    ///
    /// Accepts: [String, Data(3), Data(3)]
    public static func fromLXMFFieldValue(_ value: Any) -> IconAppearance? {
        guard let array = value as? [Any], array.count >= 3 else { return nil }

        guard let name = array[0] as? String else { return nil }

        let fgHex: String
        if let fgData = array[1] as? Data, fgData.count >= 3 {
            fgHex = rgbDataToHex(fgData)
        } else {
            return nil
        }

        let bgHex: String
        if let bgData = array[2] as? Data, bgData.count >= 3 {
            bgHex = rgbDataToHex(bgData)
        } else {
            return nil
        }

        return IconAppearance(iconName: name, foregroundColor: fgHex, backgroundColor: bgHex)
    }

    // MARK: - Helpers

    /// Convert 6-char hex RGB string to 3-byte Data.
    private static func hexToRGBData(_ hex: String) -> Data {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        return Data([
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ])
    }

    /// Convert 3-byte RGB Data to 6-char hex string.
    private static func rgbDataToHex(_ data: Data) -> String {
        data.prefix(3).map { String(format: "%02X", $0) }.joined()
    }
}
