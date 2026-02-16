// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WinNinja",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(
            name: "win-ninja",
            targets: ["WinNinja"]
        )
    ],
    targets: [
        .executableTarget(
            name: "WinNinja",
            path: "Sources/WinNinja"
        )
    ]
)
