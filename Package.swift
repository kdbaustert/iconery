// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Iconery",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Iconery",
            path: "Sources/Iconery",
            // Swift 6 language mode. Everything runs on the main actor: icons are small enough
            // that drawing and exporting them inline never stalls the window, so there is no
            // handoff for strict checking to object to, and it will catch one if a background
            // task ever appears.
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
