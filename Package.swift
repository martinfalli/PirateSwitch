// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DownloadSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure decision logic, no AppKit — unit tested.
        .target(name: "DownloadSwitchCore"),
        // Menu bar app: system calls + UI.
        .executableTarget(
            name: "DownloadSwitch",
            dependencies: ["DownloadSwitchCore"]
        ),
        .testTarget(
            name: "DownloadSwitchCoreTests",
            dependencies: ["DownloadSwitchCore"]
        ),
    ]
)
