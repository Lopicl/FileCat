// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileCatKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FileCatKit", targets: ["FileCatKit"]),
    ],
    targets: [
        .target(name: "FileCatKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "FileCatKitTests", dependencies: ["FileCatKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
