// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WallpaperPicker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "WallpaperPicker",
            path: "Sources/WallpaperPicker",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
