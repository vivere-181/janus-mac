import AppKit

/// Which Janus icon the Dock and the app switcher show while Janus runs. macOS itself only changes app icons with
/// System Settings → Appearance → Icon & widget style; this lets the icon follow Light/Dark mode instead (an app
/// can change its running icon, not the one Finder shows, without breaking its signature).
@MainActor
enum AppIcon {
    enum Style: String, CaseIterable, Identifiable {
        case matchAppearance, light, dark, system
        var id: String { rawValue }
        var title: String {
            switch self {
            case .matchAppearance: "Match Light/Dark Mode"
            case .light: "Light"
            case .dark: "Dark"
            case .system: "Same as macOS Icon Style"
            }
        }
    }

    static var style: Style {
        get { Style(rawValue: UserDefaults.standard.string(forKey: "appIcon.style") ?? "") ?? .matchAppearance }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "appIcon.style"); apply() }
    }

    /// The dark icon ships only in builds made with Xcode; without it there's nothing to choose.
    static var darkAvailable: Bool { Bundle.main.url(forResource: "JanusDark", withExtension: "icns") != nil }

    private static var observer: Any?
    /// The icon in use: "JanusDark", "Janus" or "bundle".
    private(set) static var showing = "bundle"

    static func install() {
        apply()
        // Light/Dark mode switched (by hand or at sunset).
        observer = DistributedNotificationCenter.default().addObserver(forName: .init("AppleInterfaceThemeChangedNotification"),
                                                                       object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { apply() }
        }
    }

    static func apply() {
        let dark: Bool
        switch style {
        case .system: NSApp.applicationIconImage = nil; showing = "bundle"; return   // the bundle's icon, styled by macOS
        case .light: dark = false
        case .dark: dark = true
        case .matchAppearance: dark = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
        }
        let name = dark && darkAvailable ? "JanusDark" : "Janus"
        showing = name
        NSApp.applicationIconImage = Bundle.main.url(forResource: name, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    }
}
