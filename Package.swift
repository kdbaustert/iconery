// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Iconery",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Iconery",
            path: "Sources/Iconery",
            // Swift 6 language mode. The library and every view live on the main actor. The one
            // exception is a drag or copy of many icons, which draws and writes its files on
            // every core: each work item gets plain values and its own image, and touches no
            // library state. Strict checking is what proves that stays true, so a later change
            // that hands main-actor state to those threads fails to compile.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "IconeryTests",
            dependencies: ["Iconery"],
            path: "Tests/IconeryTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
