// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ClaudeMeter",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ClaudeMeter",
            path: "Sources/ClaudeMeter",
            exclude: ["Resources/Info.plist"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClaudeMeterTests",
            dependencies: ["ClaudeMeter"],
            path: "Tests/ClaudeMeterTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
