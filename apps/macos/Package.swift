// swift-tools-version:5.10
//
// Ekagrachit native components.
//
//  - EkagrachitCore: platform-independent logic (session state machine,
//    deadlines, bridge protocol, framing, IPC, geometry, window matching).
//    Builds and is unit-tested on macOS and Linux.
//  - ekagrachit-host: Chrome Native Messaging host (stdio <-> Unix socket relay).
//  - Ekagrachit: the macOS menu bar app (AppKit/SwiftUI; macOS only).
import PackageDescription

var products: [Product] = [
    .library(name: "EkagrachitCore", targets: ["EkagrachitCore"]),
    .executable(name: "ekagrachit-host", targets: ["ekagrachit-host"]),
]

var targets: [Target] = [
    .target(name: "EkagrachitCore", path: "Sources/EkagrachitCore"),
    .executableTarget(name: "ekagrachit-host", dependencies: ["EkagrachitCore"], path: "Sources/EkagrachitHost"),
    .testTarget(name: "EkagrachitCoreTests", dependencies: ["EkagrachitCore"], path: "Tests/EkagrachitCoreTests"),
]

#if os(macOS)
products.append(.executable(name: "Ekagrachit", targets: ["Ekagrachit"]))
targets.append(
    .executableTarget(
        name: "Ekagrachit",
        dependencies: ["EkagrachitCore"],
        path: "Sources/EkagrachitApp",
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("ApplicationServices"),
            .linkedFramework("Carbon"),
            .linkedFramework("ServiceManagement"),
        ]
    )
)
#endif

let package = Package(
    name: "Ekagrachit",
    platforms: [.macOS(.v13)],
    products: products,
    targets: targets
)
