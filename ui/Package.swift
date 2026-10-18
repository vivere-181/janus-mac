// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AndroidUI",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "KDEConnectKit"),
        .target(name: "WidgetFeed"),
        .executableTarget(name: "Android", dependencies: ["KDEConnectKit", "WidgetFeed", "NativeEngine", "JanusLink"]),
        // The Notes widgets (packaged as an app extension by tools/build-ui.sh).
        .executableTarget(name: "JanusWidgets", dependencies: ["WidgetFeed"],
                          // App extensions start in NSExtensionMain (it sets up the extension, then runs the bundle).
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        // The native engine (R40): the KDE Connect protocol in Swift, replacing the separate KDE engine.
        .target(name: "JanusLink"),
        // The native engine's object model: answers the app's engine calls from JanusLink (KDE's daemon's shape).
        .target(name: "NativeEngine", dependencies: ["JanusLink", "KDEConnectKit"]),
        .executableTarget(name: "linkprobe", dependencies: ["JanusLink"]),
        .testTarget(name: "JanusLinkTests", dependencies: ["JanusLink"]),
    ],
    swiftLanguageModes: [.v5]
)
