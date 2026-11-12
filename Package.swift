// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sigil",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Sigil",
            path: "Sources/Sigil"
        ),
        .testTarget(
            name: "SigilTests",
            dependencies: ["Sigil"],
            path: "Tests/SigilTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
