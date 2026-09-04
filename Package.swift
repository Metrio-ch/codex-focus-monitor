// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "KaylaMonitor",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "KaylaMonitorCore", targets: ["KaylaMonitorCore"]),
        .executable(name: "KaylaMonitor", targets: ["KaylaMonitor"]),
        .executable(name: "kayla-monitor-hook", targets: ["KaylaMonitorHook"])
    ],
    targets: [
        .target(name: "KaylaMonitorCore"),
        .executableTarget(
            name: "KaylaMonitor",
            dependencies: ["KaylaMonitorCore"]
        ),
        .executableTarget(
            name: "KaylaMonitorHook",
            dependencies: ["KaylaMonitorCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
