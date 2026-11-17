// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHTunnelCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SSHTunnelCore", targets: ["SSHTunnelCore"])],
    targets: [
        .target(name: "SSHTunnelCore", path: "SSHTunnelManager/SSHTunnelManager",
                exclude: ["SSHTunnelManagerApp.swift", "Views", "Assets.xcassets", "SSHTunnelManager.entitlements"]),
        .testTarget(name: "SSHTunnelCoreTests", dependencies: ["SSHTunnelCore"], path: "Tests")
    ]
)
