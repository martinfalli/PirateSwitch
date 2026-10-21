// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PirateSwitch",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure decision logic, no AppKit — unit tested.
        .target(name: "PirateSwitchCore"),
        // Menu bar app: system calls + UI.
        .executableTarget(
            name: "PirateSwitch",
            dependencies: ["PirateSwitchCore"]
        ),
        .testTarget(
            name: "PirateSwitchCoreTests",
            dependencies: ["PirateSwitchCore"]
        ),
    ]
)
