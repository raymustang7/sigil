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
        )
    ],
    swiftLanguageModes: [.v5]
)
