import AppKit
import SwiftUI

/// Janus's colours (shared/icon/COLORS.md, R32): navy from the icon, the same roles as the phone app, each with a light
/// and a dark value. Used instead of the system accent for everything the app colours itself; window chrome stays
/// native.
enum Janus {
    private static func color(_ name: String, _ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: "janus." + name) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark]).map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            let v = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }

    /// Accent: buttons, selections, links, toggles, progress.
    static let primary = color("primary", 0x1B4684, 0xA8C8FC)
    /// Text and icons on a `primary` fill.
    static let onPrimary = color("onPrimary", 0xFFFFFF, 0x023063)
    static let primaryContainer = color("primaryContainer", 0xD3E4FF, 0x1B4684)
    static let onPrimaryContainer = color("onPrimaryContainer", 0x001B3D, 0xD3E4FF)
    static let secondary = color("secondary", 0x505F78, 0xB8C7E4)
    /// Cards on the window background.
    static let card = color("card", 0xF6F9FF, 0x242A37)
    static let outlineVariant = color("outlineVariant", 0xBEC7D7, 0x3D475B)
}

extension Color {
    static let janus = Color(nsColor: Janus.primary)
    static let janusOn = Color(nsColor: Janus.onPrimary)
    static let janusContainer = Color(nsColor: Janus.primaryContainer)
    static let janusOnContainer = Color(nsColor: Janus.onPrimaryContainer)
    static let janusCard = Color(nsColor: Janus.card)
    static let janusOutline = Color(nsColor: Janus.outlineVariant)
}
