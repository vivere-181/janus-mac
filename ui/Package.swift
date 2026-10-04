// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AndroidUI",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "KDEConnectKit"),
        .executableTarget(name: "Android", dependencies: ["KDEConnectKit"]),
        .executableTarget(name: "dbusprobe", dependencies: ["KDEConnectKit"]),
    ],
    swiftLanguageModes: [.v5]
)
