// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HangarCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HangarCore", targets: ["HangarCore"]),
        .library(name: "HangarResponsibility", targets: ["HangarResponsibility"]),
        .executable(name: "hangarctl", targets: ["hangarctl"]),
        .executable(name: "hangar-server", targets: ["hangar-server"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/dduan/TOMLDecoder", from: "0.4.5"),
    ],
    targets: [
        .target(name: "HangarCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
        .target(name: "HangarResponsibility"),
        .testTarget(name: "HangarCoreTests", dependencies: ["HangarCore"]),
        .target(
            name: "hangarctlKit",
            dependencies: [
                "HangarCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Info.plist is linked in by the app's Bundle helper executables phase (project.yml), not here:
        // unsafeFlags would make SwiftPM refuse this package as a dependency
        .executableTarget(name: "hangarctl", dependencies: ["hangarctlKit"], exclude: ["Info.plist"]),
        // debug-only fixture: it imports hangarctlKit @testable, and release builds name their products.
        .executableTarget(name: "session-wait-watchdog-probe", dependencies: ["hangarctlKit"]),
        .testTarget(
            name: "hangarctlKitTests",
            dependencies: ["hangarctlKit", "hangarctl", "session-wait-watchdog-probe"],
            exclude: ["Fixtures"]
        ),
        .target(name: "HangarServerKit", dependencies: ["HangarCore"]),
        .executableTarget(
            name: "hangar-server",
            dependencies: ["HangarServerKit", "HangarCore", .product(name: "ArgumentParser", package: "swift-argument-parser")]
        ),
        .testTarget(name: "HangarServerTests", dependencies: ["HangarServerKit", "hangar-server"]),
    ],
    swiftLanguageModes: [.v6]
)

#if os(Linux)
// Foundation's attributed Markdown parser is Darwin only; hangar-server parses with swift-markdown instead
package.dependencies.append(.package(url: "https://github.com/swiftlang/swift-markdown", exact: "0.8.0"))
package.targets[0].dependencies.append(.product(name: "Markdown", package: "swift-markdown"))
#endif

#if os(macOS)
package.products.append(.executable(name: "hangar-session-host", targets: ["hangar-session-host"]))
package.targets += [
    .target(name: "SessionHostTrampoline"),
    .target(name: "SessionHostRuntime", dependencies: ["SessionHostTrampoline", "HangarResponsibility", "HangarCore"]),
    .executableTarget(name: "hangar-session-host", dependencies: ["SessionHostRuntime"]),
    // The fixtures need a socket client they can copy into a test bundle, which /usr/bin/nc
    // cannot be (see the target's own comment).
    .executableTarget(name: "session-host-test-client"),
    .executableTarget(name: "session-host-pty-probe"),
    .testTarget(name: "SessionHostRuntimeTests",
                dependencies: ["SessionHostRuntime", "hangar-session-host", "session-host-test-client",
                               "session-host-pty-probe"]),
]
#endif
