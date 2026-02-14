// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ListWindows",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .executable(
            name: "list-windows",
            targets: ["ListWindows"]
        )
    ],
    targets: [
        .executableTarget(
            name: "ListWindows",
            path: "Sources/ListWindows"
        )
    ]
)
